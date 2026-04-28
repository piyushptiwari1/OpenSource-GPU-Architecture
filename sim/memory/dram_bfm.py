"""Cocotb-friendly DRAM BFM with pluggable backends.

C-6 of the integration plan.

Three backends are exposed via the `MEM_MODEL` environment variable:

- ``simple``     — pure-Python in-memory dictionary plus a configurable
                   fixed read/write latency. Always available, no native
                   dependencies. This is the default and is what public
                   CI exercises.
- ``ramulator2`` — driven through a thin CFFI wrapper around Ramulator2's
                   C API. Optional; only loaded when ``ramulator2`` is
                   importable AND ``MEM_CONFIG`` points at a YAML that
                   the shared library understands.
- ``dramsim3``   — same idea, against DRAMSim3. Fallback only.

The cocotb test harness instantiates the backend via :func:`build_backend`
and then drives it with one ``read`` / ``write`` call per memory beat. A
backend reports ``ready`` after the timing model says the request has
been served. This keeps the BFM trivial to plug into existing testbenches
without reaching into the simulator's C++ side.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

# yaml is part of the dev dependency set already (mkdocs etc).
import yaml

__all__ = [
    "DRAMConfig",
    "MemoryBackend",
    "SimpleBackend",
    "build_backend",
    "load_config",
]


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DRAMConfig:
    """Subset of the upstream DRAM yaml shared by all backends.

    Backends are free to read additional fields out of the raw yaml, but
    everything in this dataclass is required for the simple backend to
    produce a believable latency.
    """

    name: str
    # Bus / channel geometry.
    channels: int
    ranks: int
    banks_per_rank: int
    # Capacity in MiB (for sanity-checking address width).
    capacity_mib: int
    # Timing: cycles of latency for an unloaded read / write, plus the
    # tCK in picoseconds. The simple backend uses these directly.
    read_latency_ck: int
    write_latency_ck: int
    tck_ps: int
    # The full yaml document, opaque to this layer; passed verbatim to
    # the native backend constructors.
    raw: dict


def load_config(path: str | os.PathLike[str]) -> DRAMConfig:
    """Load a DRAM config YAML from disk."""
    p = Path(path)
    if not p.is_file():
        raise FileNotFoundError(f"DRAM config not found: {p}")
    raw = yaml.safe_load(p.read_text())
    if not isinstance(raw, dict):
        raise ValueError(f"DRAM config must be a mapping, got {type(raw).__name__}")
    try:
        return DRAMConfig(
            name=str(raw["name"]),
            channels=int(raw["channels"]),
            ranks=int(raw["ranks"]),
            banks_per_rank=int(raw["banks_per_rank"]),
            capacity_mib=int(raw["capacity_mib"]),
            read_latency_ck=int(raw["timing"]["read_latency_ck"]),
            write_latency_ck=int(raw["timing"]["write_latency_ck"]),
            tck_ps=int(raw["timing"]["tck_ps"]),
            raw=raw,
        )
    except KeyError as exc:  # pragma: no cover - validated by tests
        raise ValueError(f"missing required DRAM config field: {exc}") from exc


# ---------------------------------------------------------------------------
# Backend protocol + simple implementation
# ---------------------------------------------------------------------------


class MemoryBackend(Protocol):
    """Common interface every backend implements.

    Addresses are in bytes. Sizes are limited to whatever the backend's
    bus width is; the simple backend is byte-addressable but reports
    word-sized timing.
    """

    name: str
    config: DRAMConfig

    def read(self, addr: int, size: int = 4) -> tuple[int, int]:
        """Return ``(value, latency_ck)`` for an unloaded read."""

    def write(self, addr: int, value: int, size: int = 4) -> int:
        """Return ``latency_ck`` for the write."""

    def reset(self) -> None:
        """Forget all stored state. Latency model is unaffected."""


class SimpleBackend:
    """Reference backend: a Python dict plus a constant-latency timer.

    The simple backend ignores bank/rank conflict modelling — it is meant
    to keep CI cheap, not to be cycle-accurate. When a workload genuinely
    needs DRAM-bank interleaving, switch to the ramulator2 backend.
    """

    name = "simple"

    def __init__(self, config: DRAMConfig) -> None:
        self.config = config
        self._cells: dict[int, int] = {}

    def read(self, addr: int, size: int = 4) -> tuple[int, int]:
        if addr < 0:
            raise ValueError(f"negative address: {addr}")
        if size not in (1, 2, 4, 8):
            raise ValueError(f"unsupported access size: {size}")
        value = 0
        for i in range(size):
            value |= (self._cells.get(addr + i, 0) & 0xFF) << (8 * i)
        return value, self.config.read_latency_ck

    def write(self, addr: int, value: int, size: int = 4) -> int:
        if addr < 0:
            raise ValueError(f"negative address: {addr}")
        if size not in (1, 2, 4, 8):
            raise ValueError(f"unsupported access size: {size}")
        for i in range(size):
            self._cells[addr + i] = (value >> (8 * i)) & 0xFF
        return self.config.write_latency_ck

    def reset(self) -> None:
        self._cells.clear()


# ---------------------------------------------------------------------------
# Optional native backends (CFFI wrappers, lazy-loaded)
# ---------------------------------------------------------------------------


def _load_ramulator2(config: DRAMConfig) -> MemoryBackend:
    try:
        # The cffi wrapper for Ramulator2 lives outside this repo (built by
        # CMake into a shared lib alongside the cppref). When that artefact
        # is not present, fall through with a clear error so the user knows
        # to opt in or stick with the simple backend.
        import opengpu_ramulator2  # type: ignore[import-not-found]  # noqa: PLC0415
    except ImportError as exc:
        raise RuntimeError(
            "MEM_MODEL=ramulator2 requested but the opengpu_ramulator2 "
            "Python extension is not installed. Build it via "
            "`cmake -DOPENGPU_RAMULATOR2=ON sim/memory && cmake --build` "
            "or fall back to MEM_MODEL=simple."
        ) from exc
    return opengpu_ramulator2.Backend(config)  # pragma: no cover


def _load_dramsim3(config: DRAMConfig) -> MemoryBackend:
    try:
        import opengpu_dramsim3  # type: ignore[import-not-found]  # noqa: PLC0415
    except ImportError as exc:
        raise RuntimeError(
            "MEM_MODEL=dramsim3 requested but opengpu_dramsim3 is not "
            "installed. Build it via "
            "`cmake -DOPENGPU_DRAMSIM3=ON sim/memory && cmake --build` "
            "or fall back to MEM_MODEL=simple."
        ) from exc
    return opengpu_dramsim3.Backend(config)  # pragma: no cover


def build_backend(
    *,
    model: str | None = None,
    config_path: str | os.PathLike[str] | None = None,
) -> MemoryBackend:
    """Construct a backend from environment variables (or explicit args).

    Resolution order:
        1. explicit ``model``/``config_path`` arguments,
        2. ``MEM_MODEL`` / ``MEM_CONFIG`` environment variables,
        3. ``simple`` model with ``configs/ddr4_2400.yaml``.
    """
    chosen_model = (model or os.environ.get("MEM_MODEL") or "simple").strip().lower()

    here = Path(__file__).resolve().parent
    default_config = here / "configs" / "ddr4_2400.yaml"
    chosen_path = Path(config_path or os.environ.get("MEM_CONFIG") or default_config)
    cfg = load_config(chosen_path)

    if chosen_model == "simple":
        return SimpleBackend(cfg)
    if chosen_model == "ramulator2":
        return _load_ramulator2(cfg)
    if chosen_model == "dramsim3":
        return _load_dramsim3(cfg)
    raise ValueError(f"unknown MEM_MODEL={chosen_model!r}; expected simple|ramulator2|dramsim3")
