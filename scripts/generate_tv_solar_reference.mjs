#!/usr/bin/env node
/**
 * Execute the original HomeDisplay TypeScript; do not reimplement its equations.
 * Usage: <reference-root>/node_modules/.bin/tsx scripts/generate_tv_solar_reference.mjs <reference-root>
 * The generated snapshots validate a native port of an approximate visual model,
 * not astronomical/navigation accuracy.
 */
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';

const targetRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const referenceRoot = path.resolve(process.argv[2] || process.env.NAKU_SOLAR_REFERENCE_ROOT || '');
if (!process.argv[2] && !process.env.NAKU_SOLAR_REFERENCE_ROOT) {
  throw new Error('Pass the existing HomeDisplay reference repository root.');
}
const { solarPosition, solarAltitude, solarPhaseAt } = await import(
  pathToFileURL(path.join(referenceRoot, 'lib/geo/solar-position.ts')).href
);
const cases = [
  ['equinox-midnight', '2026-03-20T00:00:00.000Z'],
  ['equinox-noon', '2026-03-20T12:00:00.000Z'],
  ['equinox-late', '2026-03-20T23:59:59.000Z'],
  ['summer-solstice', '2026-06-21T12:00:00.000Z'],
  ['winter-solstice', '2026-12-21T12:00:00.000Z'],
  ['original-shanghai-day', '2026-09-17T05:00:00.000Z'],
  ['one-hour-later', '2026-09-17T06:00:00.000Z'],
  ['twelve-hours-later', '2026-09-17T17:00:00.000Z'],
  ['before-leap-day', '2024-02-28T23:59:59.000Z'],
  ['leap-day-start', '2024-02-29T00:00:00.000Z'],
  ['leap-day-noon', '2024-02-29T12:00:00.000Z'],
  ['leap-day-end', '2024-02-29T23:59:59.000Z'],
  ['after-leap-day', '2024-03-01T00:00:00.000Z'],
  ['before-year-start', '2025-12-31T23:59:59.000Z'],
  ['year-start', '2026-01-01T00:00:00.000Z'],
  ['year-end', '2026-12-31T23:59:59.000Z'],
  ['next-year-start', '2027-01-01T00:00:00.000Z'],
  ['current-shanghai-noon', '2026-10-29T04:00:00.000Z'],
  ['current-shanghai-midnight', '2026-10-29T16:00:00.000Z'],
  ['current-fractional-minute', '2026-10-29T05:37:37.000Z'],
  ['current-milliseconds-ignored-like-original', '2026-10-29T05:37:37.987Z'],
];
const fixtures = cases.map(([name, iso]) => {
  const date = new Date(iso), sun = solarPosition(date);
  return {
    name, iso, epochMillis: date.getTime(), latitude: sun.latitude, longitude: sun.longitude,
    originalDirection: sun.direction,
    nativeDirection: { x: -sun.direction.z, y: sun.direction.y, z: sun.direction.x },
    shanghaiAltitude: solarAltitude(31.23, 121.47, date),
    shanghaiPhase: solarPhaseAt(31.23, 121.47, date),
  };
});
const files = ['lib/geo/solar-position.ts', 'lib/geo/sphere.mjs', 'lib/geo/earth-material.ts', 'tests/earth/solar-position.test.ts'];
const sourceSha256 = {};
for (const relative of files) {
  sourceSha256[relative] = createHash('sha256').update(await fs.readFile(path.join(referenceRoot, relative))).digest('hex');
}
const outDir = path.join(targetRoot, 'test/fixtures');
await fs.mkdir(outDir, { recursive: true });
const metadata = {
  description: 'Executed actual original HomeDisplay TypeScript, with basis rotation only. NOAA approximate equations for visual day/night; not navigation or astronomy.',
  referenceRoot, sourceSha256,
  originalBasis: '(cos(lat)*cos(lon), sin(lat), -cos(lat)*sin(lon))',
  nativeBasis: '(cos(lat)*sin(lon), sin(lat), cos(lat)*cos(lon))',
  basisRotation: 'native=(-original.z, original.y, original.x)',
  precision: 'UTC seconds exactly as original; sub-second milliseconds are ignored.',
  fixtures,
};
await fs.writeFile(path.join(outDir, 'tv_solar_reference.json'), JSON.stringify(metadata, null, 2) + '\n');
const columns = ['name', 'epochMillis', 'x', 'y', 'z', 'latitude', 'longitude', 'shanghaiAltitude', 'shanghaiPhase'];
const rows = fixtures.map(f => [f.name, f.epochMillis, f.nativeDirection.x, f.nativeDirection.y, f.nativeDirection.z, f.latitude, f.longitude, f.shanghaiAltitude, f.shanghaiPhase].join('\t'));
await fs.writeFile(path.join(outDir, 'tv_solar_reference.tsv'), '# ' + columns.join('\t') + '\n' + rows.join('\n') + '\n');
console.log(`Generated ${fixtures.length} exact original-TS reference cases in test/fixtures/tv_solar_reference.{json,tsv}`);
