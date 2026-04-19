import os
import subprocess
import threading
import time
import re
from flask import Flask, jsonify, request, send_from_directory, send_file
from flask_cors import CORS

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
FRONTEND_DIST = os.path.join(BASE_DIR, "frontend", "dist")

app = Flask(__name__, static_folder=None)
CORS(app)

simulation_state = {
    "running": False,
    "completed": False,
    "test_name": None,
    "cycles": 0,
    "status": "idle",
    "log_lines": [],
    "passed": None,
    "sim_time_ns": None,
    "real_time_s": None,
}

def run_simulation_task(test_name):
    global simulation_state
    simulation_state["running"] = True
    simulation_state["completed"] = False
    simulation_state["test_name"] = test_name
    simulation_state["cycles"] = 0
    simulation_state["status"] = "running"
    simulation_state["log_lines"] = []
    simulation_state["passed"] = None
    simulation_state["sim_time_ns"] = None
    simulation_state["real_time_s"] = None

    env_prefix = (
        "export PATH=/home/runner/.local/bin:/home/runner/workspace/.pythonlibs/bin:$PATH && "
    )
    cmd = f"{env_prefix}make test_{test_name}"

    proc = subprocess.Popen(
        cmd,
        shell=True,
        executable="/bin/bash",
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        cwd=BASE_DIR,
    )

    cycles = 0
    log_lines = []
    for line in proc.stdout:
        stripped = line.strip()
        log_lines.append(stripped)

        if "ns INFO" in stripped or "ns WARNING" in stripped or "ns ERROR" in stripped:
            cycles += 1

        if "passed" in stripped.lower() and "test." in stripped.lower():
            simulation_state["passed"] = True
        if "failed" in stripped.lower() and "test." in stripped.lower():
            simulation_state["passed"] = False

        m = re.search(r"(\d+[\d.]*)\s+ns\s+INFO.*cocotb.regression.*completed", stripped, re.IGNORECASE)
        if not m:
            m = re.search(r"PASS\s+([\d.]+)", stripped)
            if m:
                simulation_state["sim_time_ns"] = float(m.group(1))
        m2 = re.search(r"REAL TIME \(s\).*?(\d+\.\d+)", stripped)
        if m2:
            simulation_state["real_time_s"] = float(m2.group(1))

        simulation_state["cycles"] = cycles
        simulation_state["log_lines"] = log_lines[-200:]

    proc.wait()
    simulation_state["running"] = False
    simulation_state["completed"] = True
    simulation_state["status"] = "completed" if simulation_state["passed"] else "failed"


@app.route("/api/simulate/<test_name>", methods=["POST"])
def start_simulation(test_name):
    if test_name not in ("matadd", "matmul"):
        return jsonify({"error": "Unknown test"}), 400
    if simulation_state["running"]:
        return jsonify({"error": "Simulation already running"}), 409
    t = threading.Thread(target=run_simulation_task, args=(test_name,), daemon=True)
    t.start()
    return jsonify({"status": "started", "test": test_name})


@app.route("/api/simulate/status")
def get_status():
    return jsonify(simulation_state)


@app.route("/api/architecture")
def get_architecture():
    return jsonify({
        "components": [
            {
                "name": "GPU",
                "children": [
                    {
                        "name": "Dispatch",
                        "description": "Assigns thread blocks to compute cores",
                        "color": "#00bcd4"
                    },
                    {
                        "name": "Device Control Register",
                        "description": "Stores device-wide settings like thread count",
                        "color": "#9c27b0"
                    },
                    {
                        "name": "Compute Cores",
                        "count": 2,
                        "color": "#3f51b5",
                        "children": [
                            {
                                "name": "Controller",
                                "description": "Core state machine (IDLE → FETCH → DECODE → EXECUTE → DONE)",
                                "color": "#5c6bc0"
                            },
                            {
                                "name": "Fetcher",
                                "description": "Retrieves instructions from program memory",
                                "color": "#5c6bc0"
                            },
                            {
                                "name": "Decoder",
                                "description": "Decodes 16-bit instructions into control signals",
                                "color": "#5c6bc0"
                            },
                            {
                                "name": "Scheduler",
                                "description": "Manages per-thread execution within a core",
                                "color": "#5c6bc0"
                            },
                            {
                                "name": "Threads",
                                "count": 4,
                                "color": "#4caf50",
                                "children": [
                                    {"name": "ALU", "description": "Arithmetic: ADD, SUB, MUL, DIV, CMP"},
                                    {"name": "LSU", "description": "Load/Store to global memory"},
                                    {"name": "Registers", "description": "16 x 8-bit registers per thread (R0-R12 + blockIdx, blockDim, threadIdx)"},
                                    {"name": "PC", "description": "Program counter with branch support"}
                                ]
                            }
                        ]
                    },
                    {
                        "name": "Program Memory",
                        "description": "Read-only 16-bit instruction memory (256 addresses)",
                        "color": "#ff9800"
                    },
                    {
                        "name": "Data Memory",
                        "description": "Read/write 8-bit data memory with 4 channels",
                        "color": "#f44336"
                    }
                ]
            }
        ],
        "isa": [
            {"opcode": "0001", "mnemonic": "BRnzp", "description": "Conditional branch based on NZP flags"},
            {"opcode": "0010", "mnemonic": "CMP", "description": "Compare two registers, set NZP flags"},
            {"opcode": "0011", "mnemonic": "ADD", "description": "Register addition"},
            {"opcode": "0100", "mnemonic": "SUB", "description": "Register subtraction"},
            {"opcode": "0101", "mnemonic": "MUL", "description": "Register multiplication"},
            {"opcode": "0110", "mnemonic": "DIV", "description": "Register division"},
            {"opcode": "0111", "mnemonic": "LDR", "description": "Load from data memory"},
            {"opcode": "1000", "mnemonic": "STR", "description": "Store to data memory"},
            {"opcode": "1001", "mnemonic": "CONST", "description": "Load 8-bit constant into register"},
            {"opcode": "1111", "mnemonic": "RET", "description": "Return / end of kernel"}
        ]
    })


@app.route("/api/memory-hierarchy")
def get_memory_hierarchy():
    return jsonify({
        "levels": [
            {
                "name": "Registers",
                "size": "16 x 8-bit per thread",
                "latency": "1 cycle",
                "bandwidth": "Highest (378 GB/s)",
                "description": "Fastest storage, local to each thread. Each thread has 16 registers (R0-R12, blockIdx, blockDim, threadIdx).",
                "color": "#7c4dff"
            },
            {
                "name": "Shared Memory / L1",
                "size": "Not implemented (in tiny-gpu)",
                "latency": "~26-50 cycles",
                "bandwidth": "High (~60 GB/s)",
                "description": "Shared across threads in a block. On-chip SRAM, much faster than global memory. tiny-gpu uses a simplified model.",
                "color": "#00bcd4"
            },
            {
                "name": "L2 Cache",
                "size": "Unified (in tiny-gpu: no explicit cache)",
                "latency": "~200 cycles",
                "bandwidth": "Medium (378 GB/s)",
                "description": "Shared across all SMs. Reduces traffic to DRAM. In tiny-gpu, memory access goes directly to the memory controller.",
                "color": "#4caf50"
            },
            {
                "name": "Global Memory (VRAM)",
                "size": "256 x 8-bit addresses",
                "latency": "~480 cycles",
                "bandwidth": "Lower (~900 GB/s peak DRAM)",
                "description": "Main GPU memory, accessible by all threads. In tiny-gpu, this is the data memory with 4 channels for parallel access.",
                "color": "#ff9800"
            },
            {
                "name": "System Memory (RAM)",
                "size": "Host-side",
                "latency": ">500 cycles",
                "bandwidth": "Lowest (~50 GB/s PCIe)",
                "description": "CPU-side memory, accessed via PCIe. tiny-gpu simulates data loading at startup before the kernel runs.",
                "color": "#f44336"
            }
        ]
    })


# Serve React frontend static files (production)
@app.route("/", defaults={"path": ""})
@app.route("/<path:path>")
def serve_frontend(path):
    dist = FRONTEND_DIST
    if path and os.path.exists(os.path.join(dist, path)):
        return send_from_directory(dist, path)
    return send_from_directory(dist, "index.html")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    host = "0.0.0.0"
    debug = os.environ.get("FLASK_DEBUG", "0") == "1"
    app.run(host=host, port=port, debug=debug)
