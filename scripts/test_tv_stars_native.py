#!/usr/bin/env python3
"""Validate production static-star geometry and native noninteractive draw wiring."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'android/app/src/main/kotlin/com/example/kazumi/NakuTVStars.java'
HARNESS = ROOT / 'test/native/NakuTVStarsTest.java'
RENDERER = ROOT / 'android/app/src/main/kotlin/com/example/kazumi/NakuTVEarth.kt'


def find_jdk():
    candidates = [Path(os.environ['JAVA_HOME'])] if os.environ.get('JAVA_HOME') else []
    javac = shutil.which('javac')
    if javac and Path(javac).resolve() != Path('/usr/bin/javac'):
        candidates.append(Path(javac).resolve().parents[1])
    candidates.append(Path('/Users/shenminghao/Documents/Codex/tools/rea/providers/jdk-21.0.12.1+1/Contents/Home'))
    for candidate in candidates:
        if (candidate / 'bin/javac').is_file() and (candidate / 'bin/java').is_file():
            return candidate
    raise SystemExit('Set JAVA_HOME to an existing JDK 17+; no Android SDK is needed.')


def main():
    source = SOURCE.read_text()
    for forbidden in ['currentTimeMillis', 'nanoTime', 'java.util.Random', 'Thread', 'Timer']:
        assert forbidden not in source, f'Geometry must not depend on {forbidden}'
    renderer = RENDERER.read_text()
    for name in ['STAR_VERTEX', 'STAR_FRAGMENT']:
        match = re.search(r'private const val ' + name + r' = """([\s\S]*?)"""', renderer)
        assert match, name
        shader = match.group(1)
        uniforms = re.findall(r'uniform\s+\w+\s+(\w+)\s*;', shader)
        assert set(uniforms) <= {'u_pointScale'}, 'Stars must not receive clocks, input or Earth matrices'
        for forbidden in ['uTime', 'uPointer', 'uSpin', 'u_model', 'u_mvp', 'u_sun', 'texture2D']:
            assert forbidden not in shader, forbidden
    draw = re.search(r'private fun drawStars\(\) \{([\s\S]*?)\n        \}', renderer).group(1)
    assert 'glDepthMask(false)' in draw and 'glDepthMask(true)' in draw
    assert 'glDisable(GLES20.GL_DEPTH_TEST)' in draw and 'glEnable(GLES20.GL_DEPTH_TEST)' in draw
    assert 'glDisable(GLES20.GL_BLEND)' in draw
    assert 'glBufferData' not in draw and 'geometry(' not in draw
    frame = renderer[renderer.index('override fun onDrawFrame'):renderer.index('private fun uploadStars')]
    assert frame.index('drawStars()') < frame.index('glUseProgram(program)')
    assert 'uploadStars()' not in frame
    jdk = find_jdk()
    workspace = ROOT / '.dart_tool/tv_stars_native'
    workspace.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='run-', dir=workspace) as directory:
        subprocess.run([str(jdk / 'bin/javac'), '-encoding', 'UTF-8', '-d', directory,
                        str(SOURCE), str(HARNESS)], check=True)
        subprocess.run([str(jdk / 'bin/java'), '-cp', directory,
                        'com.example.kazumi.NakuTVStarsTest'], check=True)
    print('PASS: static-only star uniforms, draw-before-Earth, restored GL state, no per-frame generation/upload.')
    print('Scope: production geometry and wiring; actual TV point appearance/performance requires device acceptance.')


if __name__ == '__main__':
    main()
