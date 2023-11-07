# Copyright (c) Meta Platforms, Inc. and affiliates
from typing import cast, List, Optional, Tuple

import torch

import torch.distributed.distributed_c10d as c10d
from torch.distributed._tensor.device_mesh import DeviceMesh
from torch.distributed._tensor.op_schema import (
    OpSchema,
    OpStrategy,
    OutputSharding,
    PlacementStrategy,
    RuntimeSchemaInfo,
)
from torch.distributed._tensor.ops.common_rules import pointwise_rule
from torch.distributed._tensor.ops.utils import (
    as_list,
    generate_redistribute_costs,
    normalize_dims,
    register_op_strategy,
    register_prop_rule,
)
from torch.distributed._tensor.placement_types import (
    _Partial,
    DTensorSpec,
    Placement,
    Replicate,
    Shard,
)


aten = torch.ops.aten


def _infer_reduction_dims(dims_arg: object, ndim: int) -> Optional[List[int]]:
    if dims_arg is None:
        return None
    dims = cast(List[int], as_list(dims_arg))
    dims = cast(List[int], normalize_dims(dims, ndim))
    empty_dims = [[0], [-1], []]
    if ndim == 0 and dims_arg in empty_dims:
        return None
    return dims


def _infer_reduce_dims_map(
    reduction_dims: List[int], input_ndim: int, keep_dim=False
) -> List[int]:
    reduction_dims_map = []
    new_dim_count = 0
    for input_dim in range(input_ndim):
        if input_dim in reduction_dims and not keep_dim:
            # if input dim in reduction dims, mark it as -1
            reduction_dims_map.append(-1)
        else:
            # otherwise mark it as the new dim
            reduction_dims_map.append(new_dim_count)
            new_dim_count += 1

    return reduction_dims_map


def replicate_reduction_dims(
    placements: Tuple[Placement, ...], reduction_dims: List[int]
) -> Tuple[Placement, ...]:
    # replicate the reduction dims if not reduction_linear
    new_placements: List[Placement] = []

    for p in placements:
        if p.is_partial():
            new_placements.append(Replicate())
        elif isinstance(p, Shard) and p.dim in reduction_dims:
            new_placements.append(Replicate())
        else:
            new_placements.append(p)

    return tuple(new_placements)


def map_placements_after_reduction(
    placements: Tuple[Placement, ...],
    reduction_dims: List[int],
    reduction_dims_map: List[int],
    reduction_op: c10d.ReduceOp.RedOpType,
) -> Tuple[Placement, ...]:
    """
    Map each placement based on the output shape after reduction.
    """
    new_placements: List[Placement] = []
    for placement in placements:
        if isinstance(placement, (Replicate, _Partial)):
            new_placements.append(placement)
        else:
            assert isinstance(placement, Shard)
            shard_dim = placement.dim
            new_shard_dim = reduction_dims_map[shard_dim]
            if new_shard_dim == -1 or shard_dim in reduction_dims:
                # if new_shard_dim collapsed or its in the reduction dims
                # (i.e. for the case where keepdims=True), we generate partial
                new_placements.append(_Partial(reduction_op))
            else:
                new_placements.append(Shard(new_shard_dim))
    return tuple(new_placements)


def common_reduction_strategy(
    mesh: DeviceMesh,
    input_strategy: OpStrategy,
    reduce_dims: List[int],
    keep_dim: bool = False,
    reduction_linear: bool = True,
    reduction_op: c10d.ReduceOp.RedOpType = c10d.ReduceOp.SUM,
) -> OpStrategy:
    """
    reduction_linear means that the reduction `f` follows this rule:
        f([f(a), f(b)]) = f([a, b])

    reduction linear should be super set of linearity.
    """
    # by default follow reduction input strategy
    reduction_strategy = OpStrategy([])

    for strtg in input_strategy.strategies:
        if not reduction_linear:
            # input placements for this strategy should clear out pending sum and sharding
            # on the reduction dimension
            input_placements = replicate_reduction_dims(
                strtg.output_spec.placements, reduce_dims
            )
        else:
            input_placements = strtg.output_spec.placements

        input_spec = DTensorSpec(
            mesh=mesh,
            placements=input_placements,
            tensor_meta=strtg.output_spec.tensor_meta,
        )

        reduce_dims_map = _infer_reduce_dims_map(reduce_dims, input_spec.ndim, keep_dim)
        out_placements = map_placements_after_reduction(
            input_spec.placements, reduce_dims, reduce_dims_map, reduction_op
        )
        redistribute_cost = [generate_redistribute_costs(input_strategy, input_spec)]
        reduction_strategy.strategies.append(
            PlacementStrategy(
                output_spec=DTensorSpec(
                    mesh=mesh,
                    placements=out_placements,
                ),
                input_specs=(input_spec,),
                redistribute_cost=redistribute_cost,
            )
        )

    return reduction_strategy


LINEAR_REDUCTION_OP_MAP = {
    aten.all.default: c10d.ReduceOp.SUM,
    aten.all.dim: c10d.ReduceOp.SUM,
    aten.sum.default: c10d.ReduceOp.SUM,
    aten.sum.dim_IntList: c10d.ReduceOp.SUM,
    aten.prod.default: c10d.ReduceOp.PRODUCT,
    aten.prod.dim_int: c10d.ReduceOp.PRODUCT,
    aten.prod.int_out: c10d.ReduceOp.PRODUCT,
    aten.mean.default: c10d.ReduceOp.AVG,
    aten.mean.dim: c10d.ReduceOp.AVG,
    aten.mean.out: c10d.ReduceOp.AVG,
    aten.max.default: c10d.ReduceOp.MAX,
    aten.max.dim: c10d.ReduceOp.MAX,
    aten.max.out: c10d.ReduceOp.MAX,
    aten.min.default: c10d.ReduceOp.MIN,
    aten.min.dim: c10d.ReduceOp.MIN,
    aten.min.out: c10d.ReduceOp.MIN,
}


@register_op_strategy(
    list(LINEAR_REDUCTION_OP_MAP.keys()), schema_info=RuntimeSchemaInfo(1)
)
def linear_reduction_strategy(mesh: DeviceMesh, op_schema: OpSchema) -> OpStrategy:
    args_schema = op_schema.args_schema
    input_strategy = args_schema[0]
    assert isinstance(input_strategy, OpStrategy)
    dims = None
    if len(op_schema.args_schema) > 1:
        dims = _infer_reduction_dims(args_schema[1], input_strategy.output_ndim)

    reduce_dims = list(range(input_strategy.output_ndim)) if dims is None else dims

    keep_dim = len(op_schema.args_schema) > 2 and bool(op_schema.args_schema[2])
    reduction_op = LINEAR_REDUCTION_OP_MAP[op_schema.op]
    return common_reduction_strategy(
        mesh,
        input_strategy,
        reduce_dims,
        keep_dim=keep_dim,
        reduction_linear=True,
        reduction_op=reduction_op,
    )


@register_op_strategy(
    [aten.var.correction, aten.var.correction_out],
    schema_info=RuntimeSchemaInfo(1, ["keepdim"]),
)
def var_reduction_strategy(mesh: DeviceMesh, op_schema: OpSchema) -> OpStrategy:
    args_schema = op_schema.args_schema
    input_strategy = args_schema[0]
    assert isinstance(input_strategy, OpStrategy)
    dims = None
    if len(op_schema.args_schema) > 1:
        dims = _infer_reduction_dims(args_schema[1], input_strategy.output_ndim)

    reduce_dims = list(range(input_strategy.output_ndim)) if dims is None else dims

    keep_dim = cast(bool, op_schema.kwargs_schema.get("keepdim", False))
    return common_reduction_strategy(
        mesh, input_strategy, reduce_dims, keep_dim=keep_dim, reduction_linear=False
    )


@register_prop_rule(
    [aten._log_softmax.default, aten._softmax.default], schema_info=RuntimeSchemaInfo(1)
)
def softmax_rule(op_schema: OpSchema) -> OutputSharding:
    input_spec, softmax_dim, _ = op_schema.args_schema
    input_spec = cast(DTensorSpec, input_spec)
    softmax_dim = cast(int, softmax_dim)
    dim_map = input_spec.dim_map
    if softmax_dim < len(dim_map) and dim_map[softmax_dim] >= 0:
        raise RuntimeError("Cannot run softmax on sharding dimension!")
    return OutputSharding(input_spec)


@register_prop_rule(
    [
        aten._log_softmax_backward_data.default,
        aten._softmax_backward_data.default,
    ],
    schema_info=RuntimeSchemaInfo(2),
)
def softmax_bwd_rule(op_schema: OpSchema) -> OutputSharding:
    grad_out_spec, out_spec, softmax_dim, _ = op_schema.args_schema
    grad_out_spec = cast(DTensorSpec, grad_out_spec)
    out_spec = cast(DTensorSpec, out_spec)
    softmax_dim = cast(int, softmax_dim)
    grad_out_dim_map = grad_out_spec.dim_map
    out_dim_map = out_spec.dim_map
    if softmax_dim < len(grad_out_dim_map) and (
        grad_out_dim_map[softmax_dim] >= 0 or out_dim_map[softmax_dim] >= 0
    ):
        raise RuntimeError("Cannot run _softmax_backward_data on sharding dimension!")
    return pointwise_rule(op_schema)
