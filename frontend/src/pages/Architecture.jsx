import { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { ArrowLeft, Cpu } from 'lucide-react';

export default function Architecture() {
  const [data, setData] = useState({ components: [], isa: [] });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch('/api/architecture')
      .then(res => res.json())
      .then(d => {
        setData(d);
        setLoading(false);
      });
  }, []);

  const renderTree = (node, depth = 0) => {
    return (
      <div key={node.name} className="flex flex-col gap-4">
        <motion.div 
          initial={{ opacity: 0, y: 10 }}
          animate={{ opacity: 1, y: 0 }}
          className="p-4 rounded-xl border border-[var(--border-color)] bg-[var(--bg-panel)] relative z-10"
          style={{ borderTopColor: node.color || 'var(--border-color)', borderTopWidth: 4 }}
        >
          <div className="font-bold text-lg">{node.name} {node.count ? `(x${node.count})` : ''}</div>
          {node.description && <div className="text-sm text-[var(--text-muted)] mt-2">{node.description}</div>}
        </motion.div>
        
        {node.children && node.children.length > 0 && (
          <div className="pl-8 border-l border-[var(--border-color)] ml-6 flex flex-col gap-4 py-2">
            {node.children.map(child => renderTree(child, depth + 1))}
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="min-h-screen p-8 max-w-7xl mx-auto flex flex-col gap-8">
      <header className="flex items-center justify-between border-b border-[var(--border-color)] pb-6">
        <div className="flex items-center gap-4">
          <Link to="/" className="p-2 rounded hover:bg-[var(--bg-panel)] transition-colors">
            <ArrowLeft />
          </Link>
          <h1 className="text-3xl font-bold">GPU Architecture</h1>
        </div>
        <Link 
          to="/simulate"
          className="px-6 py-2 rounded bg-[var(--accent-cyan)] text-black font-semibold text-sm hover:opacity-90 transition-opacity"
        >
          Simulation Center
        </Link>
      </header>

      {loading ? (
        <div className="flex-1 flex items-center justify-center font-mono text-[var(--accent-cyan)] animate-pulse">
          INITIALIZING_ARCHITECTURE_VIEW...
        </div>
      ) : (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-12">
          <div className="flex flex-col gap-6">
            <h2 className="text-xl font-mono text-[var(--accent-purple)] flex items-center gap-2">
              <Cpu size={20} /> Component Hierarchy
            </h2>
            <div className="bg-[var(--bg-card)] p-6 rounded-2xl border border-[var(--border-color)] overflow-x-auto">
              {data.components.map(comp => renderTree(comp))}
            </div>
          </div>

          <div className="flex flex-col gap-6">
            <h2 className="text-xl font-mono text-[var(--accent-cyan)]">Instruction Set Architecture (ISA)</h2>
            <div className="bg-[var(--bg-card)] rounded-2xl border border-[var(--border-color)] overflow-hidden">
              <table className="w-full text-left border-collapse">
                <thead>
                  <tr className="bg-[var(--bg-panel)] border-b border-[var(--border-color)] text-[var(--text-muted)] text-sm">
                    <th className="p-4 font-mono">Opcode</th>
                    <th className="p-4 font-mono">Mnemonic</th>
                    <th className="p-4">Description</th>
                  </tr>
                </thead>
                <tbody>
                  {data.isa.map((inst, i) => (
                    <motion.tr 
                      key={inst.opcode}
                      initial={{ opacity: 0, x: 20 }}
                      animate={{ opacity: 1, x: 0 }}
                      transition={{ delay: i * 0.05 }}
                      className="border-b border-[var(--border-color)] hover:bg-[var(--bg-panel)] transition-colors"
                    >
                      <td className="p-4 font-mono text-[var(--accent-cyan)]">{inst.opcode}</td>
                      <td className="p-4 font-mono font-bold">{inst.mnemonic}</td>
                      <td className="p-4 text-sm text-[var(--text-muted)]">{inst.description}</td>
                    </motion.tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
