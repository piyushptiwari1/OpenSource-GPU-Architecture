import { Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { Cpu, Activity } from 'lucide-react';

export default function Home() {
  return (
    <div className="min-h-screen flex flex-col items-center justify-center p-8 relative overflow-hidden">
      <div className="absolute top-[-20%] left-[-10%] w-[50%] h-[50%] bg-[var(--accent-purple)] opacity-20 blur-[120px] rounded-full pointer-events-none" />
      <div className="absolute bottom-[-20%] right-[-10%] w-[50%] h-[50%] bg-[var(--accent-cyan)] opacity-20 blur-[120px] rounded-full pointer-events-none" />
      
      <div className="max-w-6xl w-full grid grid-cols-1 lg:grid-cols-2 gap-12 items-center z-10">
        <motion.div 
          initial={{ opacity: 0, x: -50 }}
          animate={{ opacity: 1, x: 0 }}
          transition={{ duration: 0.8 }}
          className="flex flex-col items-start gap-6"
        >
          <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full border border-[var(--border-color)] bg-[var(--bg-panel)] text-[var(--text-muted)] text-sm font-mono">
            <Cpu size={16} className="text-[var(--accent-cyan)]" />
            <span>Minion GPU</span>
          </div>
          
          <h1 className="text-6xl md:text-8xl font-bold leading-tight tracking-tighter">
            Learn GPU <br />
            <span className="gradient-text">Architecture</span> <br />
            Visually
          </h1>
          
          <p className="text-xl text-[var(--text-muted)] max-w-lg leading-relaxed">
            A minimal educational GPU visualizer that makes invisible silicon visible. See exactly what happens inside a GPU kernel execution in real-time.
          </p>

          <div className="flex flex-col gap-3 w-full max-w-sm mt-2">
            <p className="text-sm font-mono text-[var(--text-muted)] uppercase tracking-wider">Choose a kernel to run:</p>
            <div className="flex flex-col gap-3">
              <Link 
                to="/simulate?kernel=matadd&autostart=true"
                className="px-8 py-4 rounded-xl bg-[var(--accent-cyan)] text-black font-semibold text-base flex items-center gap-3 hover:opacity-90 transition-all shadow-[0_0_20px_var(--accent-cyan-glow)]"
              >
                <Activity size={20} />
                <div className="flex flex-col items-start">
                  <span>Matrix Addition (matadd)</span>
                  <span className="text-xs font-normal opacity-70">C[i] = A[i] + B[i] — 8 threads</span>
                </div>
              </Link>
              <Link 
                to="/simulate?kernel=matmul&autostart=true"
                className="px-8 py-4 rounded-xl border-2 border-[var(--accent-purple)] bg-[var(--bg-panel)] text-[var(--text-main)] font-semibold text-base flex items-center gap-3 hover:bg-[var(--bg-card)] transition-all shadow-[0_0_20px_var(--accent-purple-glow)]"
              >
                <Activity size={20} className="text-[var(--accent-purple)]"/>
                <div className="flex flex-col items-start">
                  <span>Matrix Multiply (matmul)</span>
                  <span className="text-xs font-normal opacity-70 text-[var(--text-muted)]">C = A x B — 2x2 matrices, 4 threads</span>
                </div>
              </Link>
            </div>
          </div>
          
          <Link 
            to="/architecture"
            className="text-sm text-[var(--text-muted)] hover:text-[var(--accent-cyan)] transition-colors underline underline-offset-4"
          >
            Explore GPU Architecture instead
          </Link>
        </motion.div>
        
        <motion.div 
          initial={{ opacity: 0, scale: 0.9 }}
          animate={{ opacity: 1, scale: 1 }}
          transition={{ duration: 0.8, delay: 0.2 }}
          className="relative aspect-square rounded-2xl border border-[var(--border-color)] bg-[var(--bg-panel)] p-8 overflow-hidden shadow-2xl flex items-center justify-center"
        >
          <div className="absolute inset-0 bg-[radial-gradient(circle_at_center,var(--border-color)_1px,transparent_1px)] bg-[size:24px_24px] opacity-20" />
          
          <div className="relative w-64 h-64 border-2 border-[var(--accent-cyan)] rounded-xl bg-[var(--bg-dark)] shadow-[0_0_40px_var(--accent-cyan-glow)] flex items-center justify-center overflow-hidden">
             {/* spinning orbit ring */}
             <motion.div 
               animate={{ rotate: 360 }}
               transition={{ duration: 20, repeat: Infinity, ease: "linear" }}
               className="w-44 h-44 border border-dashed border-[var(--accent-purple)] rounded-full absolute opacity-60"
             />
             {/* chip icon — pure outlines, no fills */}
             <svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" viewBox="0 0 24 24"
               style={{fill: 'none', stroke: 'rgba(255,255,255,0.75)', strokeWidth: 1.4, strokeLinecap: 'round', strokeLinejoin: 'round', zIndex: 2, position: 'relative'}}>
               <rect x="4" y="4" width="16" height="16" rx="2" style={{fill:'none'}}/>
               <line x1="9" y1="1" x2="9" y2="4"/><line x1="15" y1="1" x2="15" y2="4"/>
               <line x1="9" y1="20" x2="9" y2="23"/><line x1="15" y1="20" x2="15" y2="23"/>
               <line x1="20" y1="9" x2="23" y2="9"/><line x1="20" y1="14" x2="23" y2="14"/>
               <line x1="1" y1="9" x2="4" y2="9"/><line x1="1" y1="14" x2="4" y2="14"/>
             </svg>
             {/* corner accent dots — positioned at fixed corners, not center */}
             {[['8px','8px'], ['8px','auto'], ['auto','8px'], ['auto','auto']].map(([t, b, l, r], i) => (
                <motion.div
                  key={i}
                  className="absolute w-2 h-2 bg-[var(--accent-cyan)] rounded-full"
                  style={{ top: t === 'auto' ? 'auto' : t, bottom: b, left: [l,'8px','8px','auto'][i] === 'auto' ? 'auto' : [l,'8px','8px','auto'][i], right: i >= 2 ? '8px' : 'auto' }}
                  animate={{ opacity: [0.4, 1, 0.4] }}
                  transition={{ duration: 1.8, repeat: Infinity, delay: i * 0.45 }}
                />
             ))}
          </div>
        </motion.div>
      </div>
    </div>
  );
}
