struct _DQVariable <: JuMP.AbstractVariable
    variable::JuMP.ScalarVariable
    unit::DQ.Quantity
end

function JuMP.build_variable(
    ::Function,
    info::JuMP.VariableInfo,
    unit::DQ.Quantity,
) 
    return _DQVariable(JuMP.ScalarVariable(info), unit)
end

function JuMP.build_variable(
    ::Function,
    info::JuMP.VariableInfo,
    dim::DQ.Dimensions,
) 
    return _DQVariable(JuMP.ScalarVariable(info), DQ.Quantity(1, dim))
end

function JuMP.add_variable(
    model::JuMP.Model,
    x::_DQVariable,
    name::String,
) 
    variable = JuMP.add_variable(model, x.variable, name)
    return DQ.Quantity(DQ.ustrip(x.unit) * variable, DQ.dimension(x.unit)) 
end

function Base.show(io::IO, qex::DQ.Quantity{JuMP.AffExpr})
    expr = DQ.ustrip(qex)
    if length(expr.terms) == 1 && expr.constant == 0.0
        var, val = first(expr.terms)
        print(io, "$var [$val $(DQ.dimension(qex))]")
        return
    end
    print(io, "$expr [$(DQ.dimension(qex))]")
end


function JuMP.value(qex::DQ.Quantity{JuMP.AffExpr})
    expr = DQ.ustrip(qex)
    if length(expr.terms) == 1 && expr.constant == 0.0
        var, val = first(expr.terms)
        return DQ.Quantity(JuMP.value(var) * val, DQ.dimension(qex))
    end
    return DQ.Quantity(JuMP.value(expr), DQ.dimension(qex))
end

struct _DQConstraint <: JuMP.AbstractConstraint
    constraint::JuMP.ScalarConstraint
    dim::DQ.Dimensions
end

function JuMP.build_constraint(
    _error::Function,
    expr::DQ.Quantity{JuMP.AffExpr},
    set::MOI.AbstractScalarSet,
) 
    return _DQConstraint(
        JuMP.build_constraint(_error, DQ.ustrip(expr), set),
        DQ.dimension(expr),
    )
end

function JuMP.add_constraint(
    model::JuMP.Model,
    c::_DQConstraint,
    name::String,
)
    constraint = JuMP.add_constraint(model, c.constraint, name)
    return DQ.Quantity(constraint, c.dim)
end

function JuMP.set_objective(model::JuMP.AbstractModel, sense::MOI.OptimizationSense, func::DQ.Quantity{JuMP.AffExpr})
    JuMP.set_objective(model, sense, DQ.ustrip(func))
end

Base.show(io::IO, con::DQ.Quantity{<:JuMP.ConstraintRef}) = print(io, "$(DQ.ustrip(con)) [$(DQ.dimension(con))]")
function JuMP.value(con::DQ.Quantity{<:JuMP.ConstraintRef})
    return DQ.Quantity(JuMP.value(DQ.ustrip(con)), DQ.dimension(con))
end
