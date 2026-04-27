import { BrowserRouter, Routes, Route } from 'react-router-dom';
import Home from './pages/Home';
import Architecture from './pages/Architecture';
import Simulate from './pages/Simulate';
import Memory from './pages/Memory';

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/architecture" element={<Architecture />} />
        <Route path="/simulate" element={<Simulate />} />
        <Route path="/memory" element={<Memory />} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;
