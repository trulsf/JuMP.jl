struct _DimVariable <: JuMP.AbstractVariable
    variable::JuMP.ScalarVariable
    dim::DQ.Dimensions
end

function JuMP.build_variable(
    ::Function,
    info::JuMP.VariableInfo,
    dim::DQ.Dimensions,
) 
    return _DimVariable(JuMP.ScalarVariable(info), dim)
end

function JuMP.add_variable(
    model::JuMP.Model,
    x::_DimVariable,
    name::String,
) 
    variable = JuMP.add_variable(model, x.variable, name)
    return DQ.Quantity(variable, x.dim)
end

Base.show(io::IO, x::DQ.Quantity{JuMP.VariableRef}) = print(io, "$(DQ.ustrip(x)) [$(DQ.dimension(x))]")
function JuMP.value(x::DQ.Quantity{JuMP.VariableRef})
    return DQ.Quantity(JuMP.value(DQ.ustrip(x)), DQ.dimension(x))
end

Base.show(io::IO, con::DQ.Quantity{<:JuMP.ConstraintRef}) = print(io, "$(DQ.ustrip(con)) [$(DQ.dimension(con))]")
function JuMP.value(con::DQ.Quantity{<:JuMP.ConstraintRef})
    return DQ.Quantity(JuMP.value(DQ.ustrip(con)), DQ.dimension(con))
end

Base.show(io::IO, ex::DQ.Quantity{JuMP.AffExpr}) = print(io, "$(DQ.ustrip(ex)) [$(DQ.dimension(ex))]")
function JuMP.value(ex::DQ.Quantity{JuMP.AffExpr})
    return DQ.Quantity(JuMP.value(DQ.ustrip(ex)), DQ.dimension(ex))
end


struct _DimConstraint <: JuMP.AbstractConstraint
    constraint::JuMP.ScalarConstraint
    dim::DQ.Dimensions
end


function JuMP.build_constraint(
    _error::Function,
    expr::DQ.Quantity{JuMP.AffExpr},
    set::MOI.AbstractScalarSet,
) 
    if !DQ.valid(expr)
        error("Constraint is not dimensionally correct")
    end
    return _DimConstraint(
        JuMP.build_constraint(_error, DQ.ustrip(expr), set),
        DQ.dimension(expr),
    )
end

function JuMP.add_constraint(
    model::JuMP.Model,
    c::_DimConstraint,
    name::String,
)
    constraint = JuMP.add_constraint(model, c.constraint, name)
    return DQ.Quantity(constraint, c.dim)
end


function JuMP.set_objective(model::JuMP.AbstractModel, sense::MOI.OptimizationSense, func::DQ.Quantity{JuMP.AffExpr})
    if !DQ.valid(func)
        error("Objective is not dimensionally correct")
    end
    JuMP.set_objective(model, sense, DQ.ustrip(func))
end
