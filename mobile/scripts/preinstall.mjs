#!/usr/bin/env zx

console.log('Running preinstall...');

if (process.env.G2_ACCESS_BUILD === '1') {
  // G2 LABS CI installs the root workspace explicitly before entering mobile.
  // Running another root bun install from here creates a recursive workspace
  // symlink loop, so skip only this redundant hop. Dependency lifecycle
  // scripts (including React Native Skia's native binary setup) remain enabled.
  console.log('G2 LABS CI: root workspace already installed; skipping recursive root bun install');
} else {
  // Navigate to parent directory and run bun install
  await $({ stdio: 'inherit', cwd: '..' })`bun install`;
}

console.log('✅ Preinstall completed successfully!');
