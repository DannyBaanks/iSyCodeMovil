import assert from 'node:assert/strict';
import test from 'node:test';
import { resolveEffectiveTheme } from './theme.ts';

test('el tema automático sigue al sistema y los manuales lo ignoran', () => {
  assert.equal(resolveEffectiveTheme('auto', true), 'dark');
  assert.equal(resolveEffectiveTheme('auto', false), 'light');
  assert.equal(resolveEffectiveTheme('dark', false), 'dark');
  assert.equal(resolveEffectiveTheme('light', true), 'light');
});
