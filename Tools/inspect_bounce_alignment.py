#!/usr/bin/env python3
"""Read-only comparison of unpadded and padded WAV exports; requires NumPy.

Never infers timeline origin from a BWF timestamp and never changes a Session.
Only matched PCM windows can support an observed content offset. RF64/RIFX and
compressed WAV are deliberately rejected rather than silently misdecoded.
"""
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path

import numpy as np


class Wave:
    def __init__(self, path):
        self.path = Path(path)
        self.bwf_time_reference = None
        self.data_offset = self.data_size = None
        fmt = None
        size = self.path.stat().st_size
        with self.path.open('rb') as f:
            header = f.read(12)
            if len(header) != 12 or header[:4] != b'RIFF' or header[8:] != b'WAVE':
                raise ValueError('Only little-endian RIFF WAVE is supported (no RF64/RIFX).')
            declared_end = struct.unpack('<I', header[4:8])[0] + 8
            if declared_end > size:
                raise ValueError('Truncated RIFF file.')
            offset = 12
            while offset + 8 <= declared_end:
                f.seek(offset)
                kind, length = struct.unpack('<4sI', f.read(8))
                start = offset + 8
                if start + length > declared_end:
                    raise ValueError('Truncated WAV chunk.')
                if kind == b'fmt ':
                    fmt = f.read(min(length, 64))
                elif kind == b'data':
                    if self.data_offset is not None:
                        raise ValueError('Multiple data chunks are unsupported.')
                    self.data_offset, self.data_size = start, length
                elif kind == b'bext' and length >= 346:
                    f.seek(start + 338)
                    self.bwf_time_reference = struct.unpack('<Q', f.read(8))[0]
                offset = start + length + (length & 1)
        if fmt is None or len(fmt) < 16 or self.data_offset is None:
            raise ValueError('Missing WAV format or audio data.')
        code, self.channels, self.rate, _, self.block, self.bits = struct.unpack('<HHIIHH', fmt[:16])
        if code == 0xfffe:
            if len(fmt) < 40 or fmt[26:40] != bytes.fromhex('000000001000800000aa00389b71'):
                raise ValueError('Unsupported WAVEFORMATEXTENSIBLE subtype.')
            code = struct.unpack('<H', fmt[24:26])[0]
            valid_bits = struct.unpack('<H', fmt[18:20])[0]
            if valid_bits not in (0, self.bits):
                raise ValueError('Packed valid-bit formats are unsupported.')
        self.code = code
        if not (1 <= self.channels <= 64 and self.rate > 0):
            raise ValueError('Invalid channel count or sample rate.')
        if (code == 1 and self.bits not in (16, 24, 32)) or (code == 3 and self.bits not in (32, 64)) or code not in (1, 3):
            raise ValueError('Only 16/24/32-bit PCM and 32/64-bit float WAV are supported.')
        if self.block != self.channels * self.bits // 8 or self.data_size % self.block:
            raise ValueError('Invalid WAV block alignment.')
        self.frames = self.data_size // self.block

    def read(self, start, count):
        if start < 0 or count < 0 or start + count > self.frames:
            raise ValueError('Audio window is out of bounds.')
        with self.path.open('rb') as f:
            f.seek(self.data_offset + start * self.block)
            raw = f.read(count * self.block)
        if self.code == 3:
            data = np.frombuffer(raw, dtype='<f4' if self.bits == 32 else '<f8').astype(np.float64)
        elif self.bits == 24:
            b = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
            data = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
            data = ((data ^ 0x800000) - 0x800000).astype(np.float64) / 8388608
        else:
            data = np.frombuffer(raw, dtype='<i2' if self.bits == 16 else '<i4').astype(np.float64)
            data /= 2 ** (self.bits - 1)
        if not np.isfinite(data).all():
            raise ValueError('Non-finite audio samples.')
        return data.reshape(count, self.channels)

    def info(self):
        digest = hashlib.sha256()
        with self.path.open('rb') as f:
            for block in iter(lambda: f.read(1024 * 1024), b''):
                digest.update(block)
        return dict(path=str(self.path.resolve()), sha256=digest.hexdigest(),
                    sample_rate=self.rate, channels=self.channels, bits=self.bits,
                    frames=self.frames, bwf_time_reference=self.bwf_time_reference)


def match_window(template, search, margin, rate):
    template = template - template.mean()
    energy = float(template @ template)
    if energy / len(template) < 1e-12:
        return {'accepted': False, 'reason': 'silent_or_constant_window'}
    n = len(template)
    fft_size = 1 << (len(search) + n - 2).bit_length()
    convolution = np.fft.irfft(np.fft.rfft(search, fft_size) *
                              np.fft.rfft(template[::-1], fft_size), fft_size)
    dots = convolution[n - 1:len(search)]
    sums = np.concatenate(([0.], np.cumsum(search)))
    squares = np.concatenate(([0.], np.cumsum(search * search)))
    window_sum = sums[n:] - sums[:-n]
    variance = np.maximum(0, squares[n:] - squares[:-n] - window_sum * window_sum / n)
    denominator = np.sqrt(energy * variance)
    scores = np.divide(dots, denominator, out=np.zeros_like(dots), where=denominator > 1e-18)
    best = int(np.argmax(scores))
    score = float(scores[best])
    # A nearby broad peak is normal; a comparable distant peak makes a tonal
    # or repeating excerpt ambiguous and cannot establish a unique offset.
    competing = scores.copy()
    exclusion = max(2, int(rate * .002))
    competing[max(0, best - exclusion):best + exclusion + 1] = -1
    second = float(competing.max())
    accepted = score >= .999 and score - second >= .005
    return dict(accepted=accepted, offset_samples=best - margin,
                correlation=score, competing_correlation=second,
                reason='unique_high_correlation' if accepted else 'weak_or_ambiguous_match')


def compare(reference, padded, selection_start=None, max_offset_seconds=.1):
    a, b = Wave(reference), Wave(padded)
    if (a.rate, a.channels) != (b.rate, b.channels):
        raise ValueError('Exports must have identical sample rates and channel counts; no implicit resampling/downmix.')
    if not math.isfinite(max_offset_seconds) or not 0 < max_offset_seconds <= 10:
        raise ValueError('max-offset-seconds must be in (0, 10].')
    if selection_start is not None and selection_start < 0:
        raise ValueError('selection-start must be a non-negative sample position.')
    margin = max(1, math.ceil(a.rate * max_offset_seconds))
    count = max(64, round(a.rate * .25))
    last = min(a.frames, b.frames) - count - margin
    results = []
    if last >= margin:
        window_count = min(5, (last - margin) // count + 1)
        for anchor in sorted(set(np.linspace(margin, last, window_count).astype(int).tolist())):
            original = a.read(anchor, count)
            channel = int(np.argmax(np.var(original, axis=0)))
            search = b.read(anchor - margin, count + margin * 2)[:, channel]
            result = match_window(original[:, channel], search, margin, a.rate)
            result.update(reference_sample=anchor, channel=channel + 1)
            results.append(result)
    accepted = [row for row in results if row['accepted']]
    offsets = {row['offset_samples'] for row in accepted}
    # Require at least three non-overlapping windows with exactly the same offset.
    supported = len(accepted) >= 3 and len(offsets) == 1
    offset = next(iter(offsets)) if supported else None
    placement = selection_start - offset if supported and selection_start is not None else None
    if placement is not None and placement < 0:
        placement = None
    return dict(schema_version=1, status='observed_consistent_offset' if supported else 'inconclusive',
                reference=a.info(), padded=b.info(), windows=results,
                offset_in_padded_samples=offset,
                proposed_placement_samples=placement,
                scope='Offsets come from sampled audio content. BWF timestamps are reported only; no timeline-origin assumption. No Session is modified.',
                limitation='Not a whole-file null test or host acceptance. Constant, silent or repeating material may be inconclusive. Review actual exports before adopting a placement rule.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', required=True, help='Unpadded WAV of the exact selection')
    parser.add_argument('--padded', required=True, help='WAV exported with Pad To Frame Boundary')
    parser.add_argument('--selection-start', type=int, help='Known original In sample, in the same sample rate as both WAVs')
    parser.add_argument('--max-offset-seconds', type=float, default=.1)
    args = parser.parse_args()
    try:
        report = compare(args.reference, args.padded, args.selection_start, args.max_offset_seconds)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
