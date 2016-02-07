#  Copyright 2015, Iain Dunning, Joey Huchette, Miles Lubin, and contributors
#  This Source Code Form is subject to the terms of the Mozilla Public
#  License, v. 2.0. If a copy of the MPL was not distributed with this
#  file, You can obtain one at http://mozilla.org/MPL/2.0/.

include("nlpmacros.jl")

import DualNumbers: Dual, epsilon

type NonlinearExprData
    nd::Vector{NodeData}
    const_values::Vector{Float64}
end

typealias NonlinearConstraint GenericRangeConstraint{NonlinearExprData}

type NLPData
    nlobj
    nlconstr::Vector{NonlinearConstraint}
    nlexpr::Vector{NonlinearExprData}
    nlconstrDuals::Vector{Float64}
    nlparamvalues::Vector{Float64}
    evaluator
end

function NonlinearExpression(m::Model,ex::NonlinearExprData)
    initNLP(m)
    nldata::NLPData = m.nlpdata
    push!(nldata.nlexpr, ex)
    return NonlinearExpression(m, length(nldata.nlexpr))
end

function newparameter(m::Model,value::Number)
    initNLP(m)
    nldata::NLPData = m.nlpdata
    push!(nldata.nlparamvalues, value)
    return NonlinearParameter(m, length(nldata.nlparamvalues))
end

getValue(p::NonlinearParameter) = p.m.nlpdata.nlparamvalues[p.index]::Float64

setValue(p::NonlinearParameter,v::Number) = (p.m.nlpdata.nlparamvalues[p.index] = v)

NLPData() = NLPData(nothing, NonlinearConstraint[], NonlinearExprData[], Float64[], Float64[], nothing)

Base.copy(::NLPData) = error("Copying nonlinear problems not yet implemented")

function initNLP(m::Model)
    if m.nlpdata === nothing
        m.nlpdata = NLPData()
    end
end

function getDual(c::ConstraintRef{NonlinearConstraint})
    initNLP(c.m)
    nldata::NLPData = c.m.nlpdata
    if length(nldata.nlconstrDuals) != length(nldata.nlconstr)
        error("Dual solution not available. Check that the model was properly solved.")
    end
    return nldata.nlconstrDuals[c.idx]
end

type FunctionStorage
    nd::Vector{NodeData}
    adj::SparseMatrixCSC{Bool,Int}
    const_values::Vector{Float64}
    forward_storage::Vector{Float64}
    partials_storage::Vector{Float64}
    reverse_storage::Vector{Float64}
    grad_sparsity::Vector{Int}
    hess_I::Vector{Int} # nonzero pattern of hessian
    hess_J::Vector{Int}
    rinfo::Coloring.RecoveryInfo # coloring info for hessians
    seed_matrix::Matrix{Float64}
    linearity::Linearity
    dependent_subexpressions::Vector{Int} # subexpressions which this function depends on, ordered for forward pass
end

type SubexpressionStorage
    nd::Vector{NodeData}
    adj::SparseMatrixCSC{Bool,Int}
    const_values::Vector{Float64}
    forward_storage::Vector{Float64}
    partials_storage::Vector{Float64}
    reverse_storage::Vector{Float64}
    forward_storage_ϵ::Vector{Float64}
    partials_storage_ϵ::Vector{Float64}
    reverse_storage_ϵ::Vector{Float64}
    linearity::Linearity
end

type JuMPNLPEvaluator <: MathProgBase.AbstractNLPEvaluator
    m::Model
    A::SparseMatrixCSC{Float64,Int} # linear constraint matrix
    parameter_values::Vector{Float64}
    has_nlobj::Bool
    linobj::Vector{Float64}
    objective::FunctionStorage
    constraints::Vector{FunctionStorage}
    subexpressions::Vector{SubexpressionStorage}
    subexpression_order::Vector{Int}
    subexpression_forward_values::Vector{Float64}
    subexpression_reverse_values::Vector{Float64}
    subexpressions_as_julia_expressions::Vector{Any}
    last_x::Vector{Float64}
    jac_storage::Vector{Float64} # temporary storage for computing jacobians
    # storage for computing hessians
    # these Float64 vectors are reinterpreted to hold multiple epsilon components
    # so the length should be multiplied by the maximum number of epsilon components
    want_hess::Bool
    forward_storage_ϵ::Vector{Float64} # (longest expression)
    partials_storage_ϵ::Vector{Float64} # (longest expression)
    reverse_storage_ϵ::Vector{Float64} # (longest expression)
    input_ϵ::Vector{Float64} # (number of variables)
    output_ϵ::Vector{Float64}# (number of variables)
    subexpression_forward_values_ϵ::Vector{Float64} # (number of subexpressions)
    subexpression_reverse_values_ϵ::Vector{Float64} # (number of subexpressions)
    # timers
    eval_f_timer::Float64
    eval_g_timer::Float64
    eval_grad_f_timer::Float64
    eval_jac_g_timer::Float64
    eval_hesslag_timer::Float64
    function JuMPNLPEvaluator(m::Model)
        d = new(m)
        numVar = m.numCols
        d.A = prepConstrMatrix(m)
        d.constraints = FunctionStorage[]
        d.last_x = fill(NaN, numVar)
        d.jac_storage = Array(Float64,numVar)
        d.eval_f_timer = 0
        d.eval_g_timer = 0
        d.eval_grad_f_timer = 0
        d.eval_jac_g_timer = 0
        d.eval_hesslag_timer = 0
        return d
    end
end

function simplify_expression(nd::Vector{NodeData}, const_values, subexpression_linearity, fixed_variables, parameter_values, x_values, subexpression_values)

    adj = adjmat(nd)
    forward_storage = zeros(length(nd))
    partials_storage = zeros(length(nd))
    linearity = classify_linearity(nd, adj, subexpression_linearity, fixed_variables)
    forward_eval(forward_storage, partials_storage, nd, adj, const_values, parameter_values, x_values, subexpression_values)
    nd_new = simplify_constants(forward_storage, nd, adj, const_values, linearity)
    return nd_new, forward_storage[1]
end

function FunctionStorage(nd::Vector{NodeData}, const_values,numVar, want_hess::Bool, subexpr::Vector{Vector{NodeData}}, dependent_subexpressions, subexpression_linearity, subexpression_edgelist, subexpression_variables, fixed_variables)

    adj = adjmat(nd)
    forward_storage = zeros(length(nd))
    partials_storage = zeros(length(nd))
    reverse_storage = zeros(length(nd))
    grad_sparsity = compute_gradient_sparsity(nd)

    for k in dependent_subexpressions
        union!(grad_sparsity, compute_gradient_sparsity(subexpr[k]))
    end

    if want_hess
        # compute hessian sparsity
        linearity = classify_linearity(nd, adj, subexpression_linearity, fixed_variables)
        edgelist = compute_hessian_sparsity(nd, adj, linearity, subexpression_edgelist, subexpression_variables)
        hess_I, hess_J, rinfo = Coloring.hessian_color_preprocess(edgelist, numVar)
        seed_matrix = Coloring.seed_matrix(rinfo)
        if linearity[1] == NONLINEAR
            @assert length(hess_I) > 0
        end
    else
        hess_I = hess_J = Int[]
        rinfo = Coloring.RecoveryInfo()
        seed_matrix = Array(Float64,0,0)
        linearity = [NONLINEAR]
    end

    return FunctionStorage(nd, adj, const_values, forward_storage, partials_storage, reverse_storage, sort(collect(grad_sparsity)), hess_I, hess_J, rinfo, seed_matrix, linearity[1],dependent_subexpressions)

end

function SubexpressionStorage(nd::Vector{NodeData}, const_values,numVar, want_hess_storage::Bool,fixed_variables,subexpression_linearity)

    adj = adjmat(nd)
    forward_storage = zeros(length(nd))
    partials_storage = zeros(length(nd))
    reverse_storage = zeros(length(nd))
    linearity = classify_linearity(nd, adj, subexpression_linearity, fixed_variables)


    if want_hess_storage # for Hess or HessVec
        forward_storage_ϵ = zeros(Float64,length(nd))
        partials_storage_ϵ = zeros(Float64,length(nd))
        reverse_storage_ϵ = zeros(Float64,length(nd))
    else
        forward_storage_ϵ = Array(Float64,0)
        reverse_storage_ϵ = Array(Float64,0)
        partials_storage_ϵ = Array(Float64,0)
    end


    return SubexpressionStorage(nd, adj, const_values, forward_storage, partials_storage, reverse_storage, forward_storage_ϵ, partials_storage_ϵ, reverse_storage_ϵ, linearity[1])

end

function MathProgBase.initialize(d::JuMPNLPEvaluator, requested_features::Vector{Symbol})
    for feat in requested_features
        if !(feat in [:Grad, :Jac, :Hess, :HessVec, :ExprGraph])
            error("Unsupported feature $feat")
            # TODO: implement Jac-vec products
            # for solvers that need them
        end
    end
    if d.eval_f_timer != 0
        # we've already been initialized
        # assume no new features are being requested.
        return
    end

    initNLP(d.m) #in case the problem is purely linear/quadratic thus far
    nldata::NLPData = d.m.nlpdata

    SIMPLIFY = d.m.simplify_nonlinear_expressions

    fixed_variables = SIMPLIFY ? d.m.colLower .== d.m.colUpper : d.m.colLower .== NaN
    d.m.colVal[fixed_variables] = d.m.colLower[fixed_variables]

    d.parameter_values = nldata.nlparamvalues

    tic()

    d.linobj, linrowlb, linrowub = prepProblemBounds(d.m)
    numVar = length(d.linobj)

    d.want_hess = (:Hess in requested_features)
    want_hess_storage = (:HessVec in requested_features) || d.want_hess

    d.has_nlobj = isa(nldata.nlobj, NonlinearExprData)
    max_expr_length = 0
    main_expressions = Array(Vector{NodeData},0)
    subexpr = Array(Vector{NodeData},0)
    for nlexpr in nldata.nlexpr
        push!(subexpr, nlexpr.nd)
    end
    if d.has_nlobj
        push!(main_expressions,nldata.nlobj.nd)
    end
    for nlconstr in nldata.nlconstr
        push!(main_expressions,nlconstr.terms.nd)
    end
    d.subexpression_order, individual_order = order_subexpressions(main_expressions,subexpr)
    if :ExprGraph in requested_features
        d.subexpressions_as_julia_expressions = Array(Any,length(subexpr))
        for k in d.subexpression_order
            ex = nldata.nlexpr[k]
            adj = adjmat(ex.nd)
            d.subexpressions_as_julia_expressions[k] = tapeToExpr(1, ex.nd, adj, ex.const_values, d.parameter_values, d.subexpressions_as_julia_expressions)
        end
    end

    subexpression_linearity = Array(Linearity, length(nldata.nlexpr))
    subexpression_variables = Array(Set{Int}, length(nldata.nlexpr))
    subexpression_edgelist = Array(Set{Tuple{Int,Int}}, length(nldata.nlexpr))
    d.subexpressions = Array(SubexpressionStorage, length(nldata.nlexpr))
    d.subexpression_forward_values = Array(Float64, length(d.subexpressions))
    d.subexpression_reverse_values = Array(Float64, length(d.subexpressions))
    for k in d.subexpression_order # only load expressions which actually are used
        if SIMPLIFY
            nd_new, forward_value = simplify_expression(nldata.nlexpr[k].nd, nldata.nlexpr[k].const_values,subexpression_linearity, fixed_variables, d.parameter_values, d.m.colVal, d.subexpression_forward_values)
        else
            nd_new = nldata.nlexpr[k].nd
            forward_value = NaN
        end
        d.subexpressions[k] = SubexpressionStorage(nd_new, nldata.nlexpr[k].const_values, numVar, want_hess_storage, fixed_variables, subexpression_linearity)
        subex = d.subexpressions[k]
        d.subexpression_forward_values[k] = forward_value
        subexpression_linearity[k] = subex.linearity
        if d.want_hess
            vars = compute_gradient_sparsity(subex.nd)
            # union with all dependent expressions
            for idx in list_subexpressions(subex.nd)
                union!(vars, subexpression_variables[idx])
            end
            subexpression_variables[k] = vars
            linearity = classify_linearity(subex.nd, subex.adj, subexpression_linearity, fixed_variables)
            edgelist = compute_hessian_sparsity(subex.nd, subex.adj, linearity,subexpression_edgelist, subexpression_variables)
            subexpression_edgelist[k] = edgelist
        end
    end

    if SIMPLIFY
        main_expressions = Array(Vector{NodeData},0)

        # simplify objective and constraint expressions
        if d.has_nlobj
            nd_new, forward_value = simplify_expression(nldata.nlobj.nd, nldata.nlobj.const_values,subexpression_linearity, fixed_variables, d.parameter_values, d.m.colVal, d.subexpression_forward_values)
            push!(main_expressions,nd_new)
        end
        for k in 1:length(nldata.nlconstr)
            nd_new, forward_value = simplify_expression(nldata.nlconstr[k].terms.nd, nldata.nlconstr[k].terms.const_values,subexpression_linearity, fixed_variables, d.parameter_values, d.m.colVal, d.subexpression_forward_values)
            push!(main_expressions,nd_new)
        end
        # recompute dependencies after simplification
        d.subexpression_order, individual_order = order_subexpressions(main_expressions,subexpr)

        subexpr = Array(Vector{NodeData},length(d.subexpressions))
        for k in d.subexpression_order
            subexpr[k] = d.subexpressions[k].nd
        end
    end


    if d.has_nlobj
        @assert length(d.m.obj.qvars1) == 0 && length(d.m.obj.aff.vars) == 0
        nd = main_expressions[1]
        d.objective = FunctionStorage(nd, nldata.nlobj.const_values, numVar, d.want_hess, subexpr, individual_order[1], subexpression_linearity, subexpression_edgelist, subexpression_variables, fixed_variables)
        max_expr_length = max(max_expr_length, length(d.objective.nd))
    end

    for k in 1:length(nldata.nlconstr)
        nlconstr = nldata.nlconstr[k]
        idx = (d.has_nlobj) ? k+1 : k
        nd = main_expressions[idx]
        push!(d.constraints, FunctionStorage(nd, nlconstr.terms.const_values, numVar, d.want_hess, subexpr, individual_order[idx], subexpression_linearity, subexpression_edgelist, subexpression_variables, fixed_variables))
        max_expr_length = max(max_expr_length, length(d.constraints[end].nd))
    end


    if d.want_hess || want_hess_storage # storage for Hess or HessVec
        d.input_ϵ = Array(Float64,d.m.numCols)
        d.output_ϵ = Array(Float64,d.m.numCols)
        d.forward_storage_ϵ = Array(Float64,max_expr_length)
        d.partials_storage_ϵ = Array(Float64,max_expr_length)
        d.reverse_storage_ϵ = Array(Float64,max_expr_length)
        d.subexpression_forward_values_ϵ = Array(Float64,length(d.subexpressions))
        d.subexpression_reverse_values_ϵ = Array(Float64,length(d.subexpressions))
    end

    tprep = toq()
    #println("Prep time: $tprep")

    # reset timers
    d.eval_f_timer = 0
    d.eval_grad_f_timer = 0
    d.eval_g_timer = 0
    d.eval_jac_g_timer = 0
    d.eval_hesslag_timer = 0

    nothing
end

MathProgBase.features_available(d::JuMPNLPEvaluator) = [:Grad, :Jac, :Hess, :HessVec, :ExprGraph]

function forward_eval_all(d::JuMPNLPEvaluator,x)
    # do a forward pass on all expressions at x
    subexpr_values = d.subexpression_forward_values
    for k in d.subexpression_order
        ex = d.subexpressions[k]
        subexpr_values[k] = forward_eval(ex.forward_storage,ex.partials_storage,ex.nd,ex.adj,ex.const_values,d.parameter_values,x,subexpr_values)
    end
    if d.has_nlobj
        ex = d.objective
        forward_eval(ex.forward_storage,ex.partials_storage,ex.nd,ex.adj,ex.const_values,d.parameter_values,x,subexpr_values)
    end
    for ex in d.constraints
        forward_eval(ex.forward_storage,ex.partials_storage,ex.nd,ex.adj,ex.const_values,d.parameter_values,x,subexpr_values)
    end
end

function reverse_eval_all(d::JuMPNLPEvaluator,x)
    # do a reverse pass on all expressions at x
    subexpr_reverse_values = d.subexpression_reverse_values
    subexpr_values = d.subexpression_forward_values
    grad_storage = d.jac_storage
    for k in d.subexpression_order
        ex = d.subexpressions[k]
        reverse_eval(ex.reverse_storage,ex.partials_storage,ex.nd,ex.adj)
    end
    if d.has_nlobj
        ex = d.objective
        reverse_eval(ex.reverse_storage,ex.partials_storage,ex.nd,ex.adj)
    end
    for ex in d.constraints
        reverse_eval(ex.reverse_storage,ex.partials_storage,ex.nd,ex.adj)
    end
    copy!(d.last_x,x)
end

function MathProgBase.eval_f(d::JuMPNLPEvaluator, x)
    tic()
    if d.last_x != x
        forward_eval_all(d,x)
        reverse_eval_all(d,x)
    end
    val = zero(eltype(x))
    if d.has_nlobj
        val = d.objective.forward_storage[1]
    else
        qobj = d.m.obj::QuadExpr
        val = dot(x,d.linobj) + qobj.aff.constant
        for k in 1:length(qobj.qvars1)
            val += qobj.qcoeffs[k]*x[qobj.qvars1[k].col]*x[qobj.qvars2[k].col]
        end
    end
    d.eval_f_timer += toq()
    return val
end

function MathProgBase.eval_grad_f(d::JuMPNLPEvaluator, g, x)
    tic()
    if d.last_x != x
        forward_eval_all(d,x)
        reverse_eval_all(d,x)
    end
    if d.has_nlobj
        fill!(g,0.0)
        ex = d.objective
        subexpr_reverse_values = d.subexpression_reverse_values
        subexpr_reverse_values[ex.dependent_subexpressions] = 0.0
        reverse_extract(g,ex.reverse_storage,ex.nd,ex.adj,subexpr_reverse_values,1.0)
        for i in length(ex.dependent_subexpressions):-1:1
            k = ex.dependent_subexpressions[i]
            subexpr = d.subexpressions[k]
            reverse_extract(g,subexpr.reverse_storage,subexpr.nd,subexpr.adj,subexpr_reverse_values,subexpr_reverse_values[k])

        end
    else
        copy!(g,d.linobj)
        qobj::QuadExpr = d.m.obj
        for k in 1:length(qobj.qvars1)
            coef = qobj.qcoeffs[k]
            g[qobj.qvars1[k].col] += coef*x[qobj.qvars2[k].col]
            g[qobj.qvars2[k].col] += coef*x[qobj.qvars1[k].col]
        end
    end
    d.eval_grad_f_timer += toq()
    return
end

function MathProgBase.eval_g(d::JuMPNLPEvaluator, g, x)
    tic()
    if d.last_x != x
        forward_eval_all(d,x)
        reverse_eval_all(d,x)
    end
    A = d.A
    for i in 1:size(A,1); g[i] = 0.0; end
    #fill!(sub(g,1:size(A,1)), 0.0)
    A_mul_B!(sub(g,1:size(A,1)),A,x)
    idx = size(A,1)+1
    quadconstr = d.m.quadconstr::Vector{QuadConstraint}
    for c::QuadConstraint in quadconstr
        aff = c.terms.aff
        v = aff.constant
        for k in 1:length(aff.vars)
            v += aff.coeffs[k]*x[aff.vars[k].col]
        end
        for k in 1:length(c.terms.qvars1)
            v += c.terms.qcoeffs[k]*x[c.terms.qvars1[k].col]*x[c.terms.qvars2[k].col]
        end
        g[idx] = v
        idx += 1
    end
    for ex in d.constraints
        g[idx] = ex.forward_storage[1]
        idx += 1
    end

    d.eval_g_timer += toq()
    #print("x = ");show(x);println()
    #println(size(A,1), " g(x) = ");show(g);println()
    return
end

function MathProgBase.eval_jac_g(d::JuMPNLPEvaluator, J, x)
    tic()
    if d.last_x != x
        forward_eval_all(d,x)
        reverse_eval_all(d,x)
    end
    fill!(J,0.0)
    idx = 1
    A = d.A
    for col = 1:size(A,2)
        for pos = nzrange(A,col)
            J[idx] = A.nzval[pos]
            idx += 1
        end
    end
    quadconstr = d.m.quadconstr::Vector{QuadConstraint}
    for c::QuadConstraint in quadconstr
        aff = c.terms.aff
        for k in 1:length(aff.vars)
            J[idx] = aff.coeffs[k]
            idx += 1
        end
        for k in 1:length(c.terms.qvars1)
            coef = c.terms.qcoeffs[k]
            qidx1 = c.terms.qvars1[k].col
            qidx2 = c.terms.qvars2[k].col

            J[idx] = coef*x[qidx2]
            J[idx+1] = coef*x[qidx1]
            idx += 2
        end
    end
    grad_storage = d.jac_storage
    subexpr_reverse_values = d.subexpression_reverse_values
    for ex in d.constraints
        nzidx = ex.grad_sparsity
        grad_storage[nzidx] = 0.0
        subexpr_reverse_values[ex.dependent_subexpressions] = 0.0

        reverse_extract(grad_storage,ex.reverse_storage,ex.nd,ex.adj,subexpr_reverse_values,1.0)
        for i in length(ex.dependent_subexpressions):-1:1
            k = ex.dependent_subexpressions[i]
            subexpr = d.subexpressions[k]
            reverse_extract(grad_storage,subexpr.reverse_storage,subexpr.nd,subexpr.adj,subexpr_reverse_values,subexpr_reverse_values[k])
        end

        for k in 1:length(nzidx)
            J[idx+k-1] = grad_storage[nzidx[k]]
        end
        idx += length(nzidx)
    end

    d.eval_jac_g_timer += toq()
    #print("x = ");show(x);println()
    #print("V ");show(J);println()
    return
end



function MathProgBase.eval_hesslag_prod(
    d::JuMPNLPEvaluator,
    h::Vector{Float64}, # output vector
    x::Vector{Float64}, # current solution
    v::Vector{Float64}, # rhs vector
    σ::Float64,         # multiplier for objective
    μ::Vector{Float64}) # multipliers for each constraint

    nldata = d.m.nlpdata::NLPData

    if d.last_x != x
        forward_eval_all(d,x)
        reverse_eval_all(d,x)
    end

    # quadratic objective
    qobj::QuadExpr = d.m.obj
    for k in 1:length(qobj.qvars1)
        col1 = qobj.qvars1[k].col
        col2 = qobj.qvars2[k].col
        coef = qobj.qcoeffs[k]
        if col1 == col2
            h[col1] += σ*2*coef*v[col1]
        else
            h[col1] += σ*coef*v[col2]
            h[col2] += σ*coef*v[col1]
        end
    end

    # quadratic constraints
    row = size(d.A,1)+1
    quadconstr = d.m.quadconstr::Vector{QuadConstraint}
    for c in quadconstr
        l = μ[row]
        for k in 1:length(c.terms.qvars1)
            col1 = c.terms.qvars1[k].col
            col2 = c.terms.qvars2[k].col
            coef = c.terms.qcoeffs[k]
            if col1 == col2
                h[col1] += l*2*coef*v[col1]
            else
                h[col1] += l*coef*v[col2]
                h[col2] += l*coef*v[col1]
            end
        end
        row += 1
    end

    input_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64}, d.input_ϵ)
    output_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64}, d.output_ϵ)
    for i in 1:length(x)
        input_ϵ[i] = ForwardDiff.Partials((v[i],))
    end

    # forward evaluate all subexpressions once
    subexpr_forward_values_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64},d.subexpression_forward_values_ϵ)
    subexpr_reverse_values_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64},d.subexpression_reverse_values_ϵ)
    forward_storage_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64},d.forward_storage_ϵ)
    reverse_storage_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64},d.reverse_storage_ϵ)
    partials_storage_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64},d.partials_storage_ϵ)
    for expridx in d.subexpression_order
        subexpr = d.subexpressions[expridx]
        sub_forward_storage_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64},subexpr.forward_storage_ϵ)
        sub_partials_storage_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64},subexpr.partials_storage_ϵ)
        subexpr_forward_values_ϵ[expridx] = forward_eval_ϵ(subexpr.forward_storage,sub_forward_storage_ϵ, subexpr.partials_storage, sub_partials_storage_ϵ, subexpr.nd, subexpr.adj, input_ϵ, subexpr_forward_values_ϵ)
    end
    # we only need to do one reverse pass through the subexpressions as well
    zero_ϵ = ForwardDiff.zero_partials(NTuple{1,Float64},1)
    fill!(subexpr_reverse_values_ϵ,zero_ϵ)
    fill!(d.subexpression_reverse_values,0.0)
    fill!(reverse_storage_ϵ,zero_ϵ)
    fill!(output_ϵ,zero_ϵ)
    if d.has_nlobj
        ex = d.objective
        forward_eval_ϵ(ex.forward_storage, forward_storage_ϵ, ex.partials_storage, partials_storage_ϵ, ex.nd,ex.adj,input_ϵ, subexpr_forward_values_ϵ)
        reverse_eval_ϵ(output_ϵ,ex.reverse_storage, reverse_storage_ϵ,ex.partials_storage, partials_storage_ϵ,ex.nd,ex.adj,d.subexpression_reverse_values,subexpr_reverse_values_ϵ, σ, zero_ϵ)
    end


    for i in 1:length(d.constraints)
        ex = d.constraints[i]
        l = μ[row]
        forward_eval_ϵ(ex.forward_storage, forward_storage_ϵ, ex.partials_storage, partials_storage_ϵ, ex.nd,ex.adj, input_ϵ,subexpr_forward_values_ϵ)
        reverse_eval_ϵ(output_ϵ, ex.reverse_storage, reverse_storage_ϵ, ex.partials_storage, partials_storage_ϵ, ex.nd,ex.adj,d.subexpression_reverse_values,subexpr_reverse_values_ϵ, l, zero_ϵ)
        row += 1
    end

    for i in length(ex.dependent_subexpressions):-1:1
        expridx = ex.dependent_subexpressions[i]
        subexpr = d.subexpressions[expridx]
        sub_reverse_storage_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64},subexpr.reverse_storage_ϵ)
        sub_partials_storage_ϵ = reinterpret(ForwardDiff.PartialsTup{1,Float64},subexpr.partials_storage_ϵ)
        reverse_eval_ϵ(output_ϵ,subexpr.reverse_storage,sub_reverse_storage_ϵ, subexpr.partials_storage, sub_partials_storage_ϵ,subexpr.nd,subexpr.adj,d.subexpression_reverse_values,subexpr_reverse_values_ϵ,d.subexpression_reverse_values[expridx],subexpr_reverse_values_ϵ[expridx])
    end

    for i in 1:length(x)
        h[i] += output_ϵ[i].data[1]
    end

end

function MathProgBase.eval_hesslag(
    d::JuMPNLPEvaluator,
    H::Vector{Float64},         # Sparse hessian entry vector
    x::Vector{Float64},         # Current solution
    obj_factor::Float64,        # Lagrangian multiplier for objective
    lambda::Vector{Float64})    # Multipliers for each constraint

    qobj = d.m.obj::QuadExpr
    nldata = d.m.nlpdata::NLPData

    d.want_hess || error("Hessian computations were not requested on the call to MathProgBase.initialize.")

    if d.last_x != x
        forward_eval_all(d,x)
        reverse_eval_all(d,x)
    end

    tic()

    # quadratic objective
    nzcount = 1
    for k in 1:length(qobj.qvars1)
        if qobj.qvars1[k].col == qobj.qvars2[k].col
            H[nzcount] = obj_factor*2*qobj.qcoeffs[k]
        else
            H[nzcount] = obj_factor*qobj.qcoeffs[k]
        end
        nzcount += 1
    end
    # quadratic constraints
    quadconstr = d.m.quadconstr::Vector{QuadConstraint}
    for i in 1:length(quadconstr)
        c = quadconstr[i]
        l = lambda[length(d.m.linconstr)+i]
        for k in 1:length(c.terms.qvars1)
            if c.terms.qvars1[k].col == c.terms.qvars2[k].col
                H[nzcount] = l*2*c.terms.qcoeffs[k]
            else
                H[nzcount] = l*c.terms.qcoeffs[k]
            end
            nzcount += 1
        end
    end

    fill!(d.input_ϵ,0.0)
    recovery_tmp_storage = d.output_ϵ
    nzcount -= 1

    if d.has_nlobj
        ex = d.objective
        nzthis = hessian_slice(d, ex, x, H, obj_factor, nzcount, recovery_tmp_storage)
        nzcount += nzthis
    end

    for i in 1:length(d.constraints)
        ex = d.constraints[i]
        nzthis = hessian_slice(d, ex, x, H, lambda[i+length(quadconstr)+length(d.m.linconstr)], nzcount, recovery_tmp_storage)
        nzcount += nzthis
    end

    d.eval_hesslag_timer += toq()
    return

end

function hessian_slice(d, ex, x, H, scale, nzcount, recovery_tmp_storage)

    nzthis = length(ex.hess_I)
    if ex.linearity == LINEAR
        @assert nzthis == 0
        return 0
    end
    R = ex.seed_matrix
    Coloring.prepare_seed_matrix!(R,ex.rinfo)
    local_to_global_idx = ex.rinfo.local_indices

    zero_ϵ = ForwardDiff.zero_partials(NTuple{1,Float64},1)

    input_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64}, d.input_ϵ)
    output_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64}, d.output_ϵ)

    subexpr_forward_values_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64},d.subexpression_forward_values_ϵ)
    subexpr_reverse_values_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64},d.subexpression_reverse_values_ϵ)
    forward_storage_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64},d.forward_storage_ϵ)
    reverse_storage_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64},d.reverse_storage_ϵ)
    partials_storage_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64},d.partials_storage_ϵ)


    # compute hessian-vector products
    num_products = size(R,2) # number of hessian-vector products
    @assert size(R,1) == length(local_to_global_idx)
    numVar = length(x)

    for k in 1:num_products

        for r in 1:length(local_to_global_idx)
            # set up directional derivatives
            @inbounds idx = local_to_global_idx[r]
            @inbounds input_ϵ[idx] = ForwardDiff.Partials((R[r,k],))
            @inbounds output_ϵ[idx] = zero_ϵ
        end

        # do a forward pass
        for expridx in ex.dependent_subexpressions
            subexpr = d.subexpressions[expridx]
            sub_forward_storage_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64},subexpr.forward_storage_ϵ)
            sub_partials_storage_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64},subexpr.partials_storage_ϵ)
            subexpr_forward_values_ϵ[expridx] = forward_eval_ϵ(subexpr.forward_storage,sub_forward_storage_ϵ,subexpr.partials_storage,sub_partials_storage_ϵ, subexpr.nd, subexpr.adj, input_ϵ, subexpr_forward_values_ϵ)
        end
        forward_eval_ϵ(ex.forward_storage,forward_storage_ϵ,ex.partials_storage, partials_storage_ϵ,ex.nd,ex.adj,input_ϵ, subexpr_forward_values_ϵ)

        # do a reverse pass
        subexpr_reverse_values_ϵ[ex.dependent_subexpressions] = zero_ϵ
        d.subexpression_reverse_values[ex.dependent_subexpressions] = 0.0

        reverse_eval_ϵ(output_ϵ, ex.reverse_storage, reverse_storage_ϵ,ex.partials_storage, partials_storage_ϵ,ex.nd,ex.adj,d.subexpression_reverse_values,subexpr_reverse_values_ϵ, 1.0, zero_ϵ)
        for i in length(ex.dependent_subexpressions):-1:1
            expridx = ex.dependent_subexpressions[i]
            subexpr = d.subexpressions[expridx]
            sub_reverse_storage_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64},subexpr.reverse_storage_ϵ)
            sub_partials_storage_ϵ = reinterpret_unsafe(ForwardDiff.PartialsTup{1,Float64},subexpr.partials_storage_ϵ)
            reverse_eval_ϵ(output_ϵ, subexpr.reverse_storage, sub_reverse_storage_ϵ,subexpr.partials_storage,sub_partials_storage_ϵ,subexpr.nd,subexpr.adj,d.subexpression_reverse_values,subexpr_reverse_values_ϵ,d.subexpression_reverse_values[expridx],subexpr_reverse_values_ϵ[expridx])
        end


        # collect directional derivatives
        for r in 1:length(local_to_global_idx)
            idx = local_to_global_idx[r]
            R[r,k] = output_ϵ[idx].data[1]
            @inbounds input_ϵ[idx] = ForwardDiff.Partials((0.0,))
        end

    end

    #hessmat_eval!(seed, d.reverse_storage_hess, d.forward_storage_hess, ex.nd, ex.adj, ex.const_values, x, d.reverse_output_vector, d.forward_input_vector, ex.rinfo.local_indices)
    # Output is in R, now recover

    #output_slice = sub(H, (nzcount+1):(nzcount+nzthis))
    output_slice = VectorView(nzcount, nzthis, pointer(H))
    Coloring.recover_from_matmat!(output_slice, R, ex.rinfo, recovery_tmp_storage)
    scale!(output_slice, scale)
    return nzthis

end

MathProgBase.isobjlinear(d::JuMPNLPEvaluator) = !d.has_nlobj && (length(d.m.obj.qvars1) == 0)
# interpret quadratic to include purely linear
MathProgBase.isobjquadratic(d::JuMPNLPEvaluator) = !d.has_nlobj

MathProgBase.isconstrlinear(d::JuMPNLPEvaluator, i::Integer) = (i <= length(d.m.linconstr))

function MathProgBase.jac_structure(d::JuMPNLPEvaluator)
    # Jacobian structure
    jac_I = Int[]
    jac_J = Int[]
    A = d.A
    for col = 1:size(A,2)
        for pos = nzrange(A,col)
            push!(jac_I, A.rowval[pos])
            push!(jac_J, col)
        end
    end
    rowoffset = size(A,1)+1
    for c::QuadConstraint in d.m.quadconstr
        aff = c.terms.aff
        for k in 1:length(aff.vars)
            push!(jac_I, rowoffset)
            push!(jac_J, aff.vars[k].col)
        end
        for k in 1:length(c.terms.qvars1)
            push!(jac_I, rowoffset)
            push!(jac_I, rowoffset)
            push!(jac_J, c.terms.qvars1[k].col)
            push!(jac_J, c.terms.qvars2[k].col)
        end
        rowoffset += 1
    end
    for ex in d.constraints
        idx = ex.grad_sparsity
        for i in 1:length(idx)
            push!(jac_I, rowoffset)
            push!(jac_J, idx[i])
        end
        rowoffset += 1
    end
    return jac_I, jac_J
end
function MathProgBase.hesslag_structure(d::JuMPNLPEvaluator)
    d.want_hess || error("Hessian computations were not requested on the call to MathProgBase.initialize.")
    hess_I = Int[]
    hess_J = Int[]

    qobj::QuadExpr = d.m.obj
    for k in 1:length(qobj.qvars1)
        qidx1 = qobj.qvars1[k].col
        qidx2 = qobj.qvars2[k].col
        if qidx2 > qidx1
            qidx1, qidx2 = qidx2, qidx1
        end
        push!(hess_I, qidx1)
        push!(hess_J, qidx2)
    end
    # quadratic constraints
    for c::QuadConstraint in d.m.quadconstr
        for k in 1:length(c.terms.qvars1)
            qidx1 = c.terms.qvars1[k].col
            qidx2 = c.terms.qvars2[k].col
            if qidx2 > qidx1
                qidx1, qidx2 = qidx2, qidx1
            end
            push!(hess_I, qidx1)
            push!(hess_J, qidx2)
        end
    end

    if d.has_nlobj
        append!(hess_I, d.objective.hess_I)
        append!(hess_J, d.objective.hess_J)
    end
    for ex in d.constraints
        append!(hess_I, ex.hess_I)
        append!(hess_J, ex.hess_J)
    end

    return hess_I, hess_J
end

# currently don't merge duplicates (this isn't required by MPB standard)
function affToExpr(aff::AffExpr, constant::Bool)
    ex = Expr(:call,:+)
    for k in 1:length(aff.vars)
        push!(ex.args, Expr(:call,:*,aff.coeffs[k],:(x[$(aff.vars[k].col)])))
    end
    if constant && aff.constant != 0
        push!(ex.args, aff.constant)
    end
    return ex
end

function quadToExpr(q::QuadExpr,constant::Bool)
    ex = Expr(:call,:+)
    for k in 1:length(q.qvars1)
        push!(ex.args, Expr(:call,:*,q.qcoeffs[k],:(x[$(q.qvars1[k].col)]), :(x[$(q.qvars2[k].col)])))
    end
    append!(ex.args, affToExpr(q.aff,constant).args[2:end])
    return ex
end

# we splat in the subexpressions (for now)
function tapeToExpr(k, nd::Vector{NodeData}, adj, const_values, parameter_values, subexpressions::Vector{Any})

    children_arr = rowvals(adj)

    nod = nd[k]
    if nod.nodetype == VARIABLE
        return Expr(:ref,:x,nod.index)
    elseif nod.nodetype == VALUE
        return const_values[nod.index]
    elseif nod.nodetype == SUBEXPRESSION
        return subexpressions[nod.index]
    elseif nod.nodetype == PARAMETER
        return parameter_values[nod.index]
    elseif nod.nodetype == CALL
        op = nod.index
        opsymbol = operators[op]
        children_idx = nzrange(adj,k)
        ex = Expr(:call,opsymbol)
        for cidx in children_idx
            push!(ex.args, tapeToExpr(children_arr[cidx], nd, adj, const_values, parameter_values, subexpressions))
        end
        return ex
    elseif nod.nodetype == CALLUNIVAR
        op = nod.index
        opsymbol = univariate_operators[op]
        cidx = first(nzrange(adj,k))
        return Expr(:call,opsymbol,tapeToExpr(children_arr[cidx], nd, adj, const_values, parameter_values, subexpressions))
    elseif nod.nodetype == COMPARISON
        op = nod.index
        opsymbol = comparison_operators[op]
        children_idx = nzrange(adj,k)
        ex = Expr(:comparison)
        for cidx in children_idx
            push!(ex.args, tapeToExpr(children_arr[cidx], nd, adj, const_values, parameter_values, subexpressions))
            push!(ex.args, opsymbol)
        end
        pop!(ex.args)
        return ex
    elseif nod.nodetype == LOGIC
        op = nod.index
        opsymbol = logic_operators[op]
        children_idx = nzrange(adj,k)
        lhs = tapeToExpr(children_arr[first(children_idx)], nd, adj, const_values, parameter_values, subexpressions)
        rhs = tapeToExpr(children_arr[last(children_idx)], nd, adj, const_values, parameter_values, subexpressions)
        return Expr(opsymbol, lhs, rhs)
    end
    error()


end


function MathProgBase.obj_expr(d::JuMPNLPEvaluator)
    if d.has_nlobj
        # for now, don't pass simplified expressions
        ex = d.m.nlpdata.nlobj
        adj = adjmat(ex.nd)
        return tapeToExpr(1, ex.nd, adj, ex.const_values, d.parameter_values, d.subexpressions_as_julia_expressions)
    else
        return quadToExpr(d.m.obj, true)
    end
end

function MathProgBase.constr_expr(d::JuMPNLPEvaluator,i::Integer)
    nlin = length(d.m.linconstr)
    nquad = length(d.m.quadconstr)
    if i <= nlin
        constr = d.m.linconstr[i]
        ex = affToExpr(constr.terms, false)
        if sense(constr) == :range
            return Expr(:comparison, constr.lb, :(<=), ex, :(<=), constr.ub)
        else
            return Expr(:comparison, ex, sense(constr), rhs(constr))
        end
    elseif i > nlin && i <= nlin + nquad
        i -= nlin
        qconstr = d.m.quadconstr[i]
        return Expr(:comparison, quadToExpr(qconstr.terms, true), qconstr.sense, 0)
    else
        i -= nlin + nquad
        # for now, don't pass simplified expressions
        constr = d.m.nlpdata.nlconstr[i]
        ex = constr.terms
        adj = adjmat(ex.nd)
        julia_expr = tapeToExpr(1, ex.nd, adj, ex.const_values, d.parameter_values, d.subexpressions_as_julia_expressions)
        if sense(constr) == :range
            return Expr(:comparison, constr.lb, :(<=), julia_expr, :(<=), constr.ub)
        else
            return Expr(:comparison, julia_expr, sense(constr), rhs(constr))
        end
    end
end

const ENABLE_NLP_RESOLVE = Array(Bool,1)
function EnableNLPResolve()
    ENABLE_NLP_RESOLVE[1] = true
end
function DisableNLPResolve()
    ENABLE_NLP_RESOLVE[1] = false
end
export EnableNLPResolve, DisableNLPResolve


function _buildInternalModel_nlp(m::Model, traits)

    linobj, linrowlb, linrowub = prepProblemBounds(m)

    nldata::NLPData = m.nlpdata
    if m.internalModelLoaded && !m.simplify_nonlinear_expressions
        @assert isa(nldata.evaluator, JuMPNLPEvaluator)
        d = nldata.evaluator
        fill!(d.last_x, NaN)
        if length(nldata.nlparamvalues) == 0 && !ENABLE_NLP_RESOLVE[1]
            # no parameters and haven't explicitly allowed resolves
            # error to prevent potentially incorrect answers
            msg = """
            There was a recent **breaking** change in behavior
            for solving sequences of nonlinear models.
            Previously, users were allowed to modify the data in the model
            by modifying the values stored in their own data arrays.
            For example:

            data = [1.0]
            @addNLConstraint(m, data[1]*x <= 1)
            solve(m)
            data[1] = 2.0
            solve(m) # coefficient is updated

            However, this behavior **no longer works**. Instead,
            nonlinear parameters defined with @defNLParam should be used.
            See the latest JuMP documentation for more information.
            It is possible that this model was exploiting the previous behavior,
            and out of extreme caution we have temporarily introduced
            this error message.
            If you are sure that you are solving the correct model,
            then call `EnableNLPResolve()` at the top of this file to disable
            this error message.
            To return to the last version of JuMP which supported the
            old behavior, run `Pkg.pin("JuMP",v"0.11.1")`.
            """
            error(msg)
        end
    else
        d = JuMPNLPEvaluator(m)
        nldata.evaluator = d
    end

    nlp_lb, nlp_ub = getConstraintBounds(m)
    numConstr = length(nlp_lb)

    m.internalModel = MathProgBase.NonlinearModel(m.solver)

    MathProgBase.loadproblem!(m.internalModel, m.numCols, numConstr, m.colLower, m.colUpper, nlp_lb, nlp_ub, m.objSense, d)
    if traits.int
        if applicable(MathProgBase.setvartype!, m.internalModel, m.colCat)
            MathProgBase.setvartype!(m.internalModel, vartypes_without_fixed(m))
        else
            error("Solver does not support discrete variables")
        end
    end

    if !any(isnan,m.colVal)
        MathProgBase.setwarmstart!(m.internalModel, m.colVal)
    else
        initval = copy(m.colVal)
        initval[isnan(m.colVal)] = 0
        MathProgBase.setwarmstart!(m.internalModel, min(max(m.colLower,initval),m.colUpper))
    end

    m.internalModelLoaded = true

    nothing
end


function solvenlp(m::Model, traits; suppress_warnings=false)

    @assert m.internalModelLoaded

    MathProgBase.optimize!(m.internalModel)
    stat = MathProgBase.status(m.internalModel)

    if stat != :Infeasible && stat != :Unbounded
        m.objVal = MathProgBase.getobjval(m.internalModel)
        m.colVal = MathProgBase.getsolution(m.internalModel)
    end

    if stat != :Optimal
        suppress_warnings || warn("Not solved to optimality, status: $stat")
    end
    if stat == :Optimal && !traits.int
        if applicable(MathProgBase.getconstrduals, m.internalModel) && applicable(MathProgBase.getreducedcosts, m.internalModel)
            nlduals = MathProgBase.getconstrduals(m.internalModel)
            m.linconstrDuals = nlduals[1:length(m.linconstr)]
            # quadratic duals currently not available, formulate as nonlinear constraint if needed
            m.nlpdata.nlconstrDuals = nlduals[length(m.linconstr)+length(m.quadconstr)+1:end]
            m.redCosts = MathProgBase.getreducedcosts(m.internalModel)
        else
            suppress_warnings || Base.warn_once("Nonlinear solver does not provide dual solutions")
        end
    end

    #d = m.nlpdata.evaluator
    #println("feval $(d.eval_f_timer)\nfgrad $(d.eval_grad_f_timer)\ngeval $(d.eval_g_timer)\njaceval $(d.eval_jac_g_timer)\nhess $(d.eval_hesslag_timer)")

    return stat::Symbol

end

# getValue for nonlinear subexpressions
function getValue(x::NonlinearExpression)
    m = x.m
    # recompute EVERYTHING here
    # could be smarter and cache

    nldata::NLPData = m.nlpdata
    subexpr = Array(Vector{NodeData},0)
    for nlexpr in nldata.nlexpr
        push!(subexpr, nlexpr.nd)
    end

    this_subexpr = nldata.nlexpr[x.index]

    max_len = length(this_subexpr.nd)

    subexpression_order, individual_order = order_subexpressions(Vector{NodeData}[this_subexpr.nd],subexpr)

    subexpr_values = Array(Float64, length(subexpr))

    for k in subexpression_order
        max_len = max(max_len, length(nldata.nlexpr[k].nd))
    end

    forward_storage = Array(Float64, max_len)
    partials_storage = Array(Float64, max_len)

    for k in subexpression_order # compute value of dependent subexpressions
        ex = nldata.nlexpr[k]
        adj = adjmat(ex.nd)
        subexpr_values[k] = forward_eval(forward_storage,partials_storage,ex.nd,adj,ex.const_values,nldata.nlparamvalues,m.colVal,subexpr_values)
    end

    adj = adjmat(this_subexpr.nd)

    return forward_eval(forward_storage,partials_storage,this_subexpr.nd,adj,this_subexpr.const_values,nldata.nlparamvalues,m.colVal,subexpr_values)
end
