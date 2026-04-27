import { useState, useEffect, useRef } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { motion } from 'framer-motion';
import { Play, Square, Activity, Database, Server, Terminal, ArrowLeft, Layers, CheckCircle, XCircle } from 'lucide-react';

export default function Simulate() {
  const [searchParams] = useSearchParams();
  const kernelParam = searchParams.get('kernel') || 'matadd';
  const autostart = searchParams.get('autostart') === 'true';

  const [status, setStatus] = useState({
    running: false,
    completed: false,
    test_name: null,
    cycles: 0,
    status: 'idle',
    log_lines: [],
    passed: null,
    sim_time_ns: null
  });

  const [selectedKernel, setSelectedKernel] = useState(kernelParam);
  const [backendError, setBackendError] = useState(false);
  const pollInterval = useRef(null);
  const hasAutoStarted = useRef(false);
  const logEndRef = useRef(null);

  const fetchStatus = () => {
    fetch('/api/simulate/status')
      .then(res => {
        if (!res.ok) throw new Error('Backend not reachable');
        setBackendError(false);
        return res.json();
      })
      .then(data => {
        setStatus(data);
        if (data.completed) {
          clearInterval(pollInterval.current);
        }
      })
      .catch(() => {
        setBackendError(true);
      });
  };

  const handleRun = (kernel) => {
    const k = kernel || selectedKernel;
    if (status.running) return;

    setStatus(prev => ({ ...prev, running: true, completed: false, status: 'running', cycles: 0, log_lines: [], passed: null }));

    fetch(`/api/simulate/${k}`, { method: 'POST' })
      .then(res => {
        if (!res.ok) throw new Error('Backend not reachable');
        setBackendError(false);
      })
      .catch(() => setBackendError(true));

    clearInterval(pollInterval.current);
    pollInterval.current = setInterval(fetchStatus, 500);
  };

  // On mount: poll status and optionally auto-start
  useEffect(() => {
    fetchStatus();

    if (autostart && !hasAutoStarted.current) {
      hasAutoStarted.current = true;
      // Small delay so the page renders first
      setTimeout(() => handleRun(kernelParam), 800);
    }

    return () => clearInterval(pollInterval.current);
  }, []);

  // Auto-scroll terminal
  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [status.log_lines]);

  const getStatusColor = () => {
    if (status.running) return 'text-[var(--accent-cyan)]';
    if (status.completed) return status.passed ? 'text-[var(--accent-green)]' : 'text-[var(--accent-red)]';
    return 'text-[var(--text-muted)]';
  };

  const kernelLabel = selectedKernel === 'matadd' ? 'Matrix Addition' : 'Matrix Multiplication';

  return (
    <div className="min-h-screen bg-[var(--bg-dark)] flex flex-col">
      {/* Header */}
      <header className="h-16 border-b border-[var(--border-color)] flex items-center justify-between px-6 bg-[var(--bg-panel)] z-10 shrink-0">
        <div className="flex items-center gap-4">
          <Link to="/" className="p-2 hover:bg-[var(--bg-card)] rounded-md transition-colors">
            <ArrowLeft size={20} />
          </Link>
          <div className="flex items-center gap-2 text-xl font-bold font-mono tracking-tight">
            <Activity className="text-[var(--accent-purple)]" size={20} />
            SIM_CONTROL
          </div>
        </div>

        <div className="flex items-center gap-4">
          {backendError && (
            <span className="text-[var(--accent-red)] text-xs font-mono bg-red-950/40 px-3 py-1 rounded border border-[var(--accent-red)]/40">
              BACKEND OFFLINE
            </span>
          )}
          <div className={`font-mono px-3 py-1 rounded text-sm border border-current ${getStatusColor()}`}>
            {status.running ? '⬤ RUNNING' : status.completed ? (status.passed ? '✓ PASSED' : '✗ FAILED') : 'IDLE'}
          </div>
          <Link to="/memory" className="flex items-center gap-2 text-sm font-semibold hover:text-[var(--accent-cyan)] transition-colors px-3 py-1.5 rounded border border-[var(--border-color)] hover:border-[var(--accent-cyan)]">
            <Layers size={14} />
            Memory
          </Link>
        </div>
      </header>

      <div className="flex-1 flex overflow-hidden min-h-0">
        {/* Main */}
        <div className="flex-1 flex flex-col p-5 gap-4 overflow-y-auto">

          {/* Kernel Controls */}
          <div className="bg-[var(--bg-card)] border border-[var(--border-color)] rounded-xl p-4 flex flex-wrap items-center gap-4">
            <div className="flex gap-3 flex-1">
              <button
                onClick={() => { setSelectedKernel('matadd'); }}
                className={`px-4 py-2 rounded-lg font-mono text-sm font-bold border transition-all ${selectedKernel === 'matadd'
                  ? 'bg-[var(--accent-cyan)] text-black border-[var(--accent-cyan)]'
                  : 'bg-[var(--bg-panel)] text-[var(--text-muted)] border-[var(--border-color)] hover:border-[var(--accent-cyan)]'}`}
                disabled={status.running}
              >
                matadd
              </button>
              <button
                onClick={() => { setSelectedKernel('matmul'); }}
                className={`px-4 py-2 rounded-lg font-mono text-sm font-bold border transition-all ${selectedKernel === 'matmul'
                  ? 'bg-[var(--accent-purple)] text-white border-[var(--accent-purple)]'
                  : 'bg-[var(--bg-panel)] text-[var(--text-muted)] border-[var(--border-color)] hover:border-[var(--accent-purple)]'}`}
                disabled={status.running}
              >
                matmul
              </button>

              <button
                onClick={() => handleRun()}
                disabled={status.running || backendError}
                className={`flex items-center gap-2 px-6 py-2 rounded-lg font-bold text-sm transition-all ml-2 ${
                  status.running
                    ? 'bg-[var(--border-color)] text-[var(--text-muted)] cursor-not-allowed'
                    : backendError
                      ? 'bg-red-900/40 text-red-400 border border-red-700 cursor-not-allowed'
                      : 'bg-[var(--accent-cyan)] text-black hover:opacity-90 shadow-[0_0_15px_var(--accent-cyan-glow)]'
                }`}
              >
                {status.running
                  ? <><Square size={14} fill="currentColor" /> RUNNING</>
                  : <><Play size={14} fill="currentColor" /> EXECUTE</>
                }
              </button>
            </div>

            <div className="flex flex-col items-end shrink-0">
              <span className="text-xs text-[var(--text-muted)] font-mono uppercase tracking-widest">Cycle Count</span>
              <motion.div
                key={status.cycles}
                initial={{ color: 'var(--accent-cyan)' }}
                animate={{ color: 'var(--text-heading)' }}
                transition={{ duration: 0.3 }}
                className="font-mono text-3xl font-bold"
              >
                {String(status.cycles).padStart(6, '0')}
              </motion.div>
            </div>
          </div>

          {/* GPU Cores Grid */}
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
            {[0, 1, 2, 3].map(core => {
              const isActive = status.running && core < 2; // tiny-gpu has 2 cores
              return (
                <div
                  key={core}
                  className={`relative border rounded-xl p-4 flex flex-col bg-[var(--bg-card)] overflow-hidden transition-all duration-300 ${
                    isActive
                      ? 'border-[var(--accent-cyan)] shadow-[0_0_18px_var(--accent-cyan-glow)]'
                      : status.completed && core < 2
                        ? status.passed ? 'border-[var(--accent-green)]' : 'border-[var(--accent-red)]'
                        : 'border-[var(--border-color)]'
                  }`}
                >
                  {isActive && (
                    <motion.div
                      className="absolute inset-0 bg-[var(--accent-cyan)] pointer-events-none"
                      animate={{ opacity: [0.03, 0.1, 0.03] }}
                      transition={{ duration: 1.4, repeat: Infinity, delay: core * 0.3 }}
                    />
                  )}

                  <div className="flex items-center justify-between border-b border-[var(--border-color)] pb-2 mb-3 z-10">
                    <div className="font-mono font-bold flex items-center gap-1.5 text-sm text-[var(--accent-purple)]">
                      <Server size={13} />
                      CORE_{core}
                    </div>
                    <div className={`w-2 h-2 rounded-full transition-all ${
                      isActive ? 'bg-[var(--accent-cyan)] animate-pulse shadow-[0_0_6px_var(--accent-cyan)]' :
                      status.completed && core < 2 ? (status.passed ? 'bg-[var(--accent-green)]' : 'bg-[var(--accent-red)]') :
                      'bg-[var(--text-muted)] opacity-40'
                    }`} />
                  </div>

                  <div className="flex flex-col gap-1.5 z-10 text-xs font-mono text-[var(--text-muted)]">
                    <div className="flex justify-between">
                      <span>STATE</span>
                      <span className={isActive ? 'text-[var(--accent-cyan)] font-bold' : status.completed && core < 2 ? (status.passed ? 'text-[var(--accent-green)]' : 'text-[var(--accent-red)]') : ''}>
                        {isActive ? 'EXECUTE' : status.completed && core < 2 ? (status.passed ? 'DONE ✓' : 'FAIL ✗') : 'IDLE'}
                      </span>
                    </div>
                    <div className="flex justify-between">
                      <span>THREADS</span>
                      <span className="text-white">{core < 2 ? '4 / 4' : '— / —'}</span>
                    </div>
                    <div className="flex justify-between">
                      <span>KERNEL</span>
                      <span className={isActive ? 'text-white' : 'opacity-40'}>
                        {core < 2 ? (status.test_name || selectedKernel) : '—'}
                      </span>
                    </div>
                    {isActive && (
                      <div className="mt-1 h-1 bg-[var(--bg-dark)] rounded-full overflow-hidden">
                        <motion.div
                          className="h-full bg-[var(--accent-cyan)]"
                          animate={{ width: ['20%', '95%', '60%', '85%'] }}
                          transition={{ duration: 2, repeat: Infinity, ease: 'linear' }}
                        />
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>

          {/* Terminal log */}
          <div className="flex-1 min-h-48 bg-[#050505] rounded-xl border border-[var(--border-color)] p-4 flex flex-col font-mono text-xs overflow-hidden">
            <div className="flex items-center gap-2 text-[var(--text-muted)] mb-2 border-b border-[#1a1a1a] pb-2">
              <Terminal size={12} />
              <span>stdout // cocotb + iverilog simulation</span>
              {status.test_name && (
                <span className="ml-auto text-[var(--accent-cyan)]">kernel: {status.test_name}</span>
              )}
            </div>
            <div className="flex-1 overflow-y-auto flex flex-col gap-0.5 pr-1">
              {status.log_lines.length === 0 ? (
                <span className="text-[var(--text-muted)] opacity-40 italic">
                  {backendError ? '// Backend API is offline — restart the Backend API workflow' : '// Press EXECUTE to run the Verilog simulation...'}
                </span>
              ) : (
                status.log_lines.map((line, i) => (
                  <div key={i} className="leading-snug break-all">
                    {line.includes('passed') || line.includes('PASS') ? (
                      <span className="text-[var(--accent-green)] font-bold">{line}</span>
                    ) : line.includes('failed') || line.includes('FAIL') || line.includes('ERROR') ? (
                      <span className="text-[var(--accent-red)]">{line}</span>
                    ) : line.includes('INFO') ? (
                      <span className="text-blue-400">{line}</span>
                    ) : line.includes('WARNING') ? (
                      <span className="text-yellow-400">{line}</span>
                    ) : (
                      <span className="text-gray-500">{line}</span>
                    )}
                  </div>
                ))
              )}
              <div ref={logEndRef} />
            </div>
          </div>

          {/* Result banner */}
          {status.completed && (
            <motion.div
              initial={{ opacity: 0, y: 10 }}
              animate={{ opacity: 1, y: 0 }}
              className={`rounded-xl border p-4 flex items-center gap-4 font-mono ${
                status.passed
                  ? 'bg-green-950/30 border-[var(--accent-green)] text-[var(--accent-green)]'
                  : 'bg-red-950/30 border-[var(--accent-red)] text-[var(--accent-red)]'
              }`}
            >
              {status.passed ? <CheckCircle size={24} /> : <XCircle size={24} />}
              <div>
                <div className="font-bold text-sm">{status.passed ? 'SIMULATION PASSED' : 'SIMULATION FAILED'}</div>
                {status.sim_time_ns && (
                  <div className="text-xs opacity-70 mt-0.5">
                    {status.sim_time_ns.toLocaleString()} ns simulated — {status.cycles} log events captured
                  </div>
                )}
              </div>
            </motion.div>
          )}
        </div>

        {/* Sidebar */}
        <div className="w-72 border-l border-[var(--border-color)] bg-[var(--bg-panel)] flex flex-col p-4 gap-3 overflow-y-auto shrink-0">
          <h3 className="font-bold text-xs text-[var(--text-muted)] uppercase tracking-wider">Architecture Stats</h3>

          <div className="bg-[var(--bg-card)] border border-[var(--border-color)] rounded-lg p-3">
            <div className="font-bold text-sm mb-2 flex items-center gap-2">
              <Database size={14} className="text-[var(--accent-cyan)]" /> L2 Cache
            </div>
            <div className="space-y-1 text-xs font-mono">
              <div className="flex justify-between text-[var(--text-muted)]">
                <span>Hit est.</span>
                <span className="text-white">{status.running ? Math.floor(status.cycles * 0.75) : (status.completed ? Math.floor(status.cycles * 0.75) : 0)}</span>
              </div>
              <div className="flex justify-between text-[var(--text-muted)]">
                <span>Miss est.</span>
                <span className="text-white">{status.running ? Math.floor(status.cycles * 0.25) : (status.completed ? Math.floor(status.cycles * 0.25) : 0)}</span>
              </div>
            </div>
          </div>

          <div className="bg-[var(--bg-card)] border border-[var(--border-color)] rounded-lg p-3">
            <div className="font-bold text-sm mb-2 text-[var(--accent-purple)]">Warp Scheduler</div>
            <div className="space-y-1 text-xs font-mono">
              <div className="flex justify-between text-[var(--text-muted)]">
                <span>Active warps</span>
                <span className="text-white">{status.running ? '2' : '0'}</span>
              </div>
              <div className="flex justify-between text-[var(--text-muted)]">
                <span>Stalled</span>
                <span className="text-white">0</span>
              </div>
              <div className="flex justify-between text-[var(--text-muted)]">
                <span>Threads/warp</span>
                <span className="text-white">4</span>
              </div>
            </div>
          </div>

          <div className="bg-[var(--bg-card)] border border-[var(--border-color)] rounded-lg p-3">
            <div className="font-bold text-sm mb-2">CUDA Cores (ALU/FPU)</div>
            <div className="space-y-1 text-xs font-mono">
              <div className="flex justify-between text-[var(--text-muted)]">
                <span>Cores active</span>
                <span className="text-white">{status.running ? '2 / 2' : '0 / 2'}</span>
              </div>
              <div className="flex justify-between text-[var(--text-muted)]">
                <span>ISA</span>
                <span className="text-white">11 ops</span>
              </div>
            </div>
          </div>

          <div className="bg-[var(--bg-card)] border border-[var(--border-color)] rounded-lg p-3">
            <div className="font-bold text-sm mb-2">Register File</div>
            <div className="space-y-1 text-xs font-mono text-[var(--text-muted)] mb-2">
              <div className="flex justify-between"><span>Regs/thread</span><span className="text-white">16</span></div>
              <div className="flex justify-between"><span>Width</span><span className="text-white">8-bit</span></div>
            </div>
            <div className="w-full bg-[var(--bg-dark)] h-1.5 rounded-full overflow-hidden">
              <motion.div
                className="h-full bg-[var(--accent-cyan)]"
                animate={{ width: status.running ? ['25%', '85%', '45%', '90%'] : status.completed ? '100%' : '0%' }}
                transition={{ duration: 2, repeat: status.running ? Infinity : 0, ease: 'linear' }}
              />
            </div>
            <div className="text-[10px] text-[var(--text-muted)] mt-1 text-right">{status.running ? 'allocating...' : status.completed ? 'freed' : 'idle'}</div>
          </div>

          <div className="mt-auto flex flex-col gap-2">
            <Link
              to="/memory"
              className="w-full py-2.5 text-center rounded-lg bg-[var(--accent-cyan)] text-black text-sm font-bold hover:opacity-90 transition-all"
            >
              Memory Hierarchy
            </Link>
            <Link
              to="/"
              className="w-full py-2.5 text-center rounded-lg border border-[var(--border-color)] text-sm font-bold hover:border-[var(--accent-purple)] transition-all"
            >
              Go to Home
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
