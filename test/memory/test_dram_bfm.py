"""Unit tests for the C-6 DRAM BFM (simple backend + dispatch logic)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

# Make sim/memory importable without installing the package.
# parents: [0]=test/memory, [1]=test, [2]=repo root.
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from sim.memory import (  # noqa: E402  (sys.path setup must precede import)
    DRAMConfig,
    SimpleBackend,
    build_backend,
    load_config,
)

CONFIGS = ROOT / "sim" / "memory" / "configs"


@pytest.mark.parametrize("name", ["ddr4_2400.yaml", "hbm2_1024.yaml"])
def test_load_config_known_presets(name: str) -> None:
    cfg = load_config(CONFIGS / name)
    assert isinstance(cfg, DRAMConfig)
    assert cfg.tck_ps > 0
    assert cfg.read_latency_ck > 0
    assert cfg.write_latency_ck > 0
    assert cfg.channels >= 1
    assert cfg.banks_per_rank >= 1


def test_load_config_missing_file(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_config(tmp_path / "does_not_exist.yaml")


def test_load_config_rejects_non_mapping(tmp_path: Path) -> None:
    p = tmp_path / "bad.yaml"
    p.write_text("- just a list\n- nope\n")
    with pytest.raises(ValueError):
        load_config(p)


def test_simple_backend_round_trip() -> None:
    cfg = load_config(CONFIGS / "ddr4_2400.yaml")
    be = SimpleBackend(cfg)

    # Empty cells read as zero.
    val, lat = be.read(0x1000, 4)
    assert val == 0
    assert lat == cfg.read_latency_ck

    # Round-trip a 32-bit value.
    wlat = be.write(0x1000, 0xDEADBEEF, 4)
    assert wlat == cfg.write_latency_ck
    val, _ = be.read(0x1000, 4)
    assert val == 0xDEADBEEF

    # Sub-word access is byte-coherent.
    assert be.read(0x1000, 1)[0] == 0xEF
    assert be.read(0x1003, 1)[0] == 0xDE


def test_simple_backend_validates_size() -> None:
    cfg = load_config(CONFIGS / "ddr4_2400.yaml")
    be = SimpleBackend(cfg)
    with pytest.raises(ValueError):
        be.read(0, size=3)
    with pytest.raises(ValueError):
        be.write(0, 0, size=5)


def test_simple_backend_rejects_negative_address() -> None:
    cfg = load_config(CONFIGS / "ddr4_2400.yaml")
    be = SimpleBackend(cfg)
    with pytest.raises(ValueError):
        be.read(-1)
    with pytest.raises(ValueError):
        be.write(-1, 0)


def test_simple_backend_reset_clears_state() -> None:
    cfg = load_config(CONFIGS / "ddr4_2400.yaml")
    be = SimpleBackend(cfg)
    be.write(0x10, 0x55AA55AA)
    assert be.read(0x10)[0] == 0x55AA55AA
    be.reset()
    assert be.read(0x10)[0] == 0x0


def test_build_backend_default() -> None:
    # No env vars → simple + ddr4_2400.
    for var in ("MEM_MODEL", "MEM_CONFIG"):
        os.environ.pop(var, None)
    be = build_backend()
    assert isinstance(be, SimpleBackend)
    assert be.config.name == "ddr4_2400"


def test_build_backend_env_override(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MEM_MODEL", "simple")
    monkeypatch.setenv("MEM_CONFIG", str(CONFIGS / "hbm2_1024.yaml"))
    be = build_backend()
    assert isinstance(be, SimpleBackend)
    assert be.config.name == "hbm2_1024"


def test_build_backend_explicit_args() -> None:
    be = build_backend(model="simple", config_path=CONFIGS / "hbm2_1024.yaml")
    assert isinstance(be, SimpleBackend)
    assert be.config.channels == 8


def test_build_backend_unknown_model() -> None:
    with pytest.raises(ValueError, match="unknown MEM_MODEL"):
        build_backend(model="nope", config_path=CONFIGS / "ddr4_2400.yaml")


def test_build_backend_ramulator2_missing_extension(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The native extension is intentionally not built in public CI.
    monkeypatch.setitem(sys.modules, "opengpu_ramulator2", None)
    with pytest.raises(RuntimeError, match="opengpu_ramulator2"):
        build_backend(model="ramulator2", config_path=CONFIGS / "ddr4_2400.yaml")


def test_build_backend_dramsim3_missing_extension(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setitem(sys.modules, "opengpu_dramsim3", None)
    with pytest.raises(RuntimeError, match="opengpu_dramsim3"):
        build_backend(model="dramsim3", config_path=CONFIGS / "ddr4_2400.yaml")
