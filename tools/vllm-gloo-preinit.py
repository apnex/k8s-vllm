#!/usr/bin/env python3
"""Pre-initialize torch.distributed with gloo backend, then exec vLLM CLI.

vLLM unconditionally calls torch.distributed.init_process_group(backend='nccl')
even at world_size=1. NCCL communicator init on Blackwell over Thunderbolt 4
with the open kernel module 580.142 takes the GPU off the bus and freezes
the host (reproduced 4+ times this session).

vLLM's init_distributed_environment skips its own init_process_group call if
torch.distributed.is_initialized() returns True. So we pre-init with the gloo
(CPU) backend - which is a no-op at world_size=1 since there are no actual
collectives to perform - and vLLM picks up the existing init.

Usage:
    python3 vllm-gloo-preinit.py serve <model> [vllm-flags...]

The first argv after the script name is the vllm subcommand (e.g. 'serve').
"""
import os
import sys


def main():
    # Standard torch.distributed env-var rendezvous: 127.0.0.1 to keep
    # everything local; port doesn't matter for world_size=1 but must be set.
    os.environ.setdefault("MASTER_ADDR", "127.0.0.1")
    os.environ.setdefault("MASTER_PORT", "29500")
    os.environ.setdefault("WORLD_SIZE", "1")
    os.environ.setdefault("RANK", "0")
    os.environ.setdefault("LOCAL_RANK", "0")

    import torch.distributed as dist

    if not dist.is_initialized():
        dist.init_process_group(
            backend="gloo",
            init_method="env://",
            world_size=1,
            rank=0,
        )
    print(
        f"vllm-gloo-preinit: torch.distributed initialized, "
        f"backend={dist.get_backend()} world_size={dist.get_world_size()} "
        f"rank={dist.get_rank()}",
        flush=True,
    )

    # Hand off to vllm's CLI. argv[0] needs to be 'vllm' (or a similar
    # name); subsequent args are the vllm subcommand and its options.
    from vllm.entrypoints.cli.main import main as vllm_main

    sys.argv = ["vllm"] + sys.argv[1:]
    sys.exit(vllm_main())


if __name__ == "__main__":
    main()
