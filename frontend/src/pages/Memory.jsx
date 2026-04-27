import { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { ArrowLeft, Layers, Zap, Clock, Database } from 'lucide-react';

export default function Memory() {
  const [levels, setLevels] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch('/api/memory-hierarchy')
      .then(res => res.json())
      .then(data => {
        setLevels(data.levels);
        setLoading(false);
      });
  }, []);

  return (
    <div className="min-h-screen bg-[var(--bg-dark)] p-8">
      <div className="max-w-5xl mx-auto flex flex-col gap-10">
        <header className="flex items-center justify-between border-b border-[var(--border-color)] pb-6">
          <div className="flex items-center gap-4">
            <Link to="/simulate" className="p-2 hover:bg-[var(--bg-panel)] rounded-md transition-colors">
              <ArrowLeft size={20} />
            </Link>
            <h1 className="text-3xl font-bold flex items-center gap-3">
              <Layers className="text-[var(--accent-cyan)]" size={32} />
              Memory Hierarchy
            </h1>
          </div>
        </header>

        {loading ? (
          <div className="text-center font-mono text-[var(--accent-cyan)] animate-pulse py-20">
            SCANNING_MEMORY_SUBSYSTEM...
          </div>
        ) : (
          <div className="relative">
            {/* Connecting line */}
            <div className="absolute left-[50%] top-0 bottom-0 w-1 bg-gradient-to-b from-[var(--accent-purple)] via-[var(--accent-cyan)] to-[var(--accent-red)] opacity-20 transform -translate-x-1/2 rounded-full" />
            
            <div className="flex flex-col gap-8">
              {levels.map((level, i) => (
                <motion.div 
                  key={level.name}
                  initial={{ opacity: 0, y: 20 }}
                  animate={{ opacity: 1, y: 0 }}
                  transition={{ delay: i * 0.15 }}
                  className="relative z-10 flex flex-col md:flex-row gap-6 md:gap-12 items-center"
                >
                  <div className="flex-1 w-full text-right bg-[var(--bg-card)] p-6 rounded-2xl border border-[var(--border-color)] shadow-lg hover:border-[var(--accent-cyan)] transition-colors group">
                    <h3 className="text-2xl font-bold mb-2 group-hover:text-[var(--accent-cyan)] transition-colors">{level.name}</h3>
                    <p className="text-[var(--text-muted)] text-sm">{level.description}</p>
                  </div>
                  
                  {/* Center Node */}
                  <div 
                    className="w-16 h-16 rounded-full bg-[var(--bg-dark)] border-4 flex items-center justify-center shrink-0 z-10 shadow-[0_0_20px_rgba(0,0,0,0.5)]"
                    style={{ borderColor: level.color }}
                  >
                    <div className="w-4 h-4 rounded-full" style={{ backgroundColor: level.color }} />
                  </div>
                  
                  <div className="flex-1 w-full flex flex-col gap-3">
                    <div className="bg-[var(--bg-panel)] rounded-lg p-3 border border-[var(--border-color)] flex items-center gap-3">
                      <Zap size={16} className="text-[var(--accent-cyan)] shrink-0" />
                      <div className="flex flex-col">
                        <span className="text-[10px] uppercase text-[var(--text-muted)] font-bold tracking-wider">Bandwidth</span>
                        <span className="font-mono text-sm font-bold">{level.bandwidth}</span>
                      </div>
                    </div>
                    <div className="bg-[var(--bg-panel)] rounded-lg p-3 border border-[var(--border-color)] flex items-center gap-3">
                      <Clock size={16} className="text-[var(--accent-purple)] shrink-0" />
                      <div className="flex flex-col">
                        <span className="text-[10px] uppercase text-[var(--text-muted)] font-bold tracking-wider">Latency</span>
                        <span className="font-mono text-sm font-bold">{level.latency}</span>
                      </div>
                    </div>
                    <div className="bg-[var(--bg-panel)] rounded-lg p-3 border border-[var(--border-color)] flex items-center gap-3">
                      <Database size={16} className="text-[var(--accent-green)] shrink-0" />
                      <div className="flex flex-col">
                        <span className="text-[10px] uppercase text-[var(--text-muted)] font-bold tracking-wider">Capacity</span>
                        <span className="font-mono text-sm font-bold">{level.size}</span>
                      </div>
                    </div>
                  </div>
                </motion.div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
