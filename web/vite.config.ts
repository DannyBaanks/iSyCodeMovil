import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react(), tailwindcss()],
  // El panel importa el motor del Bridge (../Bridge/workspace); Vite debe poder leer fuera de web/.
  server: { fs: { allow: ['..'] } },
});
