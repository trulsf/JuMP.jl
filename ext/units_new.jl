
struct QuantityScale{T,D} <: DQ.AbstractQuantity{T,D}
    value::T
    dimensions::D
    scale::Float64
end

QuantityScale(value, dim) = QuantityScale(value, dim, 1.0)

function _scale_to_string(scale::Float64)
    if scale == 1.0
        return ""
    end

    all_prefixes = (
        f=1e-15, p=1e-12, n=1e-9, μ=1e-6, u=1e-6, m=1e-3, c=1e-2, d=1e-1,
        k=1e3, M=1e6, G=1e9
    )
    for (prefix, value) in zip(keys(all_prefixes), values(all_prefixes))
        if scale == value
            return prefix
        end
    end
    return "$scale "
end

function _simplify_dim(dim::DQ.Dimensions)

    testq = DQ.Quantity(1.0, DQ.dimension(dim))
    if testq == DQ.Units.W
        return "W"
    elseif testq == DQ.Units.J
        return "J"
    end
    return dim
end

function Base.show(io::IO, qex::QuantityScale)
    expr = DQ.ustrip(qex)
    scale_str = _scale_to_string(qex.scale)
    dim_str = _simplify_dim(DQ.dimension(qex))
    print(io, "$(expr / qex.scale) [$(scale_str)$(dim_str)]")
end

#function Base.show(io::IO, qex::QuantityScale)
#    print(io, "$(DQ.ustrip(qex) / qex.scale) [$(qex.scale) $(DQ.dimension(qex))]")
#end


struct _ScaledVariable <: JuMP.AbstractVariable
    variable::JuMP.ScalarVariable
    unit::DQ.Quantity
end

function JuMP.build_variable(
    ::Function,
    info::JuMP.VariableInfo,
    unit::DQ.Quantity,
) 
    return _ScaledVariable(JuMP.ScalarVariable(info), unit)
end

function JuMP.build_variable(
    ::Function,
    info::JuMP.VariableInfo,
    dim::DQ.Dimensions,
) 
    return _ScaledVariable(JuMP.ScalarVariable(info), DQ.Quantity(1.0, dim))
end

function JuMP.add_variable(
    model::JuMP.Model,
    x::_ScaledVariable,
    name::String,
) 
    variable = JuMP.add_variable(model, x.variable, name)
    scale = DQ.ustrip(x.unit)
    return QuantityScale(scale * variable, DQ.dimension(x.unit), scale) 
end


function JuMP.value(qex::QuantityScale{JuMP.AffExpr})
    expr = DQ.ustrip(qex)
    return QuantityScale(JuMP.value(expr), DQ.dimension(qex), qex.scale)
end

struct _DQConstraint <: JuMP.AbstractConstraint
    constraint::JuMP.ScalarConstraint
    dim::DQ.Dimensions
end

function JuMP.build_constraint(
    _error::Function,
    expr::QuantityScale{JuMP.AffExpr},
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
    return QuantityScale(constraint, c.dim)
end

function JuMP.set_objective(model::JuMP.AbstractModel, sense::MOI.OptimizationSense, func::QuantityScale{JuMP.AffExpr})
    JuMP.set_objective(model, sense, DQ.ustrip(func))
end

Base.show(io::IO, con::QuantityScale{<:JuMP.ConstraintRef}) = print(io, "$(DQ.ustrip(con)) [$(con.scale) $(DQ.dimension(con))]")
function JuMP.value(con::QuantityScale{<:JuMP.ConstraintRef})
    return DQ.Quantity(JuMP.value(DQ.ustrip(con)), DQ.dimension(con))
end
