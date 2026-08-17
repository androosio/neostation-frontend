import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_chd/flutter_chd.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/ra_hash_policy.dart';
import 'package:neostation/utils/disc/chd_disc_image.dart';
import 'package:neostation/utils/disc/ra_disc_hash.dart';

import 'ra_disc_hash_test.dart'
    show directory, psxExecutableHeader, sector, volumeDescriptor;

/// The CHD reader, against CHDs built here rather than mocked.
///
/// This is the part of disc hashing that cannot be checked by reasoning about
/// sectors: whether a track's frames are where the track layout says they are.
/// The maths — 4-frame padding between tracks, pregaps that occupy disc
/// addresses without occupying file space — is invisible on a single-track
/// PlayStation disc and decides everything on a PC Engine CD.
///
/// `flutter test` runs in the Dart VM with no plugin build, so the native
/// library is built here and loaded by path.
void main() {
  // Built here rather than in setUpAll: `skip:` is evaluated as the tests are
  // registered, which happens before any setUp runs.
  final skip = _buildNativeLibrary();

  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('neostation_chd_test');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Writes [chd] to a file and returns its path.
  String write(Uint8List chd, [String name = 'game.chd']) {
    final path = '${temp.path}/$name';
    File(path).writeAsBytesSync(chd);
    return path;
  }

  group('reading a CHD', () {
    test('reads a single data track by sector', () async {
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [ChdTrackSpec(type: 'MODE1_RAW', frames: 40)],
            sectors: {
              5: dataSector(List.filled(2048, 0x5A)),
              39: dataSector(List.filled(2048, 0x39)),
            },
          ),
        ),
      );

      expect(disc.tracks, hasLength(1));
      expect(disc.tracks.single.number, 1);
      expect(disc.tracks.single.isData, isTrue);
      expect(disc.tracks.single.sectors, 40);
      expect(disc.tracks.single.startLba, 0);
      expect(disc.readSector(0, 5)!.first, 0x5A);
      // The last sector of the track lives in a hunk the earlier reads did not
      // touch, so this also covers the hunk cache moving on.
      expect(disc.readSector(0, 39)!.first, 0x39);
      expect(disc.readSector(0, 40), isNull, reason: 'past the track');

      disc.close();
    }, skip: skip);

    test('puts a second track past the first, padded to four frames', () async {
      // 41 frames of audio occupy 44 in the file: tracks start on a multiple of
      // four. Get that wrong and every sector of the data track is off by
      // three, which reads as a corrupt disc rather than as a layout bug.
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [
              ChdTrackSpec(type: 'AUDIO', frames: 41),
              ChdTrackSpec(type: 'MODE1_RAW', frames: 20),
            ],
            sectors: {44: dataSector(List.filled(2048, 0xC7))},
          ),
        ),
      );

      expect(disc.tracks, hasLength(2));
      expect(disc.tracks[1].isData, isTrue);
      // The disc addresses the second track right after the first: no padding
      // in the numbering, only in the file.
      expect(disc.tracks[1].startLba, 41);
      expect(disc.readSector(1, 0)!.first, 0xC7);

      disc.close();
    }, skip: skip);

    test('skips a pregap the file actually stores', () async {
      // A stored pregap is 150 frames of file that are not sector 0 of the
      // track. Reading them as data would hash the wrong bytes entirely.
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [
              ChdTrackSpec(type: 'AUDIO', frames: 20),
              ChdTrackSpec(
                type: 'MODE1_RAW',
                frames: 170,
                pregap: 150,
                pregapType: 'MODE1_RAW',
              ),
            ],
            sectors: {
              // Frame 20 is where the stored pregap begins, 170 where the
              // track's own data does.
              20: dataSector(List.filled(2048, 0x11)),
              170: dataSector(List.filled(2048, 0x22)),
            },
          ),
        ),
      );

      expect(disc.tracks[1].sectors, 20, reason: '170 frames less the pregap');
      expect(disc.tracks[1].startLba, 170, reason: '20 played, then 150 gap');
      expect(disc.readSector(1, 0)!.first, 0x22);

      disc.close();
    }, skip: skip);

    test('counts a virtual pregap in the addressing but not the file', () async {
      // PGTYPE:V means the pregap is silence the drive generates, so it shifts
      // the sector numbering without occupying a single frame of the image.
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [
              ChdTrackSpec(type: 'AUDIO', frames: 20),
              ChdTrackSpec(type: 'MODE1_RAW', frames: 20, pregap: 150),
            ],
            sectors: {20: dataSector(List.filled(2048, 0x33))},
          ),
        ),
      );

      expect(disc.tracks[1].sectors, 20);
      expect(disc.tracks[1].startLba, 170);
      expect(disc.readSector(1, 170 - 170)!.first, 0x33);

      disc.close();
    }, skip: skip);

    test('finds the user data behind a mode 2 subheader', () async {
      // PlayStation discs are mode 2 form 1: the payload starts 24 bytes in,
      // not 16. Eight bytes of drift produces a plausible-looking hash that
      // matches nothing.
      final disc = ChdDisc.open(
        write(
          buildChd(
            tracks: [ChdTrackSpec(type: 'MODE2_RAW', frames: 8)],
            sectors: {3: mode2Sector(List.filled(2048, 0x77))},
          ),
        ),
      );

      final read = disc.readSector(0, 3)!;
      expect(read.every((byte) => byte == 0x77), isTrue);

      disc.close();
    }, skip: skip);

    test('reports a file that is not a CHD rather than throwing later', () {
      final path = '${temp.path}/broken.chd';
      File(path).writeAsBytesSync(Uint8List(4096));

      expect(() => ChdDisc.open(path), throwsA(isA<ChdException>()));
    }, skip: skip);
  });

  group('hashing a CHD end to end', () {
    test('produces the PlayStation hash from inside the image', () async {
      // The whole chain over a real container: hunk decompression, track
      // layout, sector offsets, ISO9660, and the hash itself.
      final exeHeader = psxExecutableHeader(2048);
      final payload = sector(List.filled(64, 0xAB));
      final path = write(
        buildChd(
          tracks: [ChdTrackSpec(type: 'MODE1_RAW', frames: 40)],
          sectors: {
            16: dataSector(volumeDescriptor(rootSector: 20, rootSize: 2048)),
            20: dataSector(
              directory({
                'SYSTEM.CNF;1': [22, 100],
                'SLUS_007.27;1': [24, 4096],
              }).first,
            ),
            22: dataSector(
              sector('BOOT = cdrom:\\SLUS_007.27;1\r\n'.codeUnits),
            ),
            24: dataSector(exeHeader),
            25: dataSector(payload),
          },
        ),
      );

      final hash = await RaDiscHash.compute(RaHashAlgo.psx, path);

      expect(
        hash,
        crypto.md5.convert([
          ...'SLUS_007.27'.codeUnits,
          ...exeHeader,
          ...payload,
        ]).toString(),
      );
    }, skip: skip);

    test('exposes the same tracks through the disc image', () async {
      final path = write(
        buildChd(
          tracks: [
            ChdTrackSpec(type: 'AUDIO', frames: 12),
            ChdTrackSpec(type: 'MODE1_RAW', frames: 8),
          ],
          sectors: {12: dataSector(List.filled(2048, 0x99))},
        ),
      );

      final image = await ChdDiscImage.open(path);

      expect(image, isNotNull);
      expect(image!.tracks, hasLength(2));
      expect(image.firstDataTrackIndex, 1);
      // The image takes disc-absolute sectors, as a filesystem refers to them.
      final read = await image.readSector(1, 12);
      expect(read?.first, 0x99);
      expect(await image.readSector(1, 11), isNull, reason: 'before the track');
      await image.close();
    }, skip: skip);
  });
}

/// Builds the plugin's native library and points the package at it, returning
/// a skip reason when that is not possible here.
String? _buildNativeLibrary() {
  const unavailable = 'the flutter_chd native library could not be built here';
  final buildDir = Directory('build/flutter_chd_test');
  final library = File('${buildDir.path}/libflutter_chd$_librarySuffix');

  if (!library.existsSync()) {
    try {
      final configure = Process.runSync('cmake', [
        '-S',
        'packages/flutter_chd/src',
        '-B',
        buildDir.path,
        '-DCMAKE_BUILD_TYPE=Release',
      ]);
      if (configure.exitCode != 0) return unavailable;
      final build = Process.runSync('cmake', [
        '--build',
        buildDir.path,
        '-j',
        '4',
      ]);
      if (build.exitCode != 0) return unavailable;
    } on ProcessException {
      return unavailable;
    }
  }
  if (!library.existsSync()) return unavailable;

  chdLibraryOverridePath = library.absolute.path;
  return null;
}

String get _librarySuffix {
  if (Platform.isMacOS) return '.dylib';
  if (Platform.isWindows) return '.dll';
  return '.so';
}

// --- Building a CHD ---------------------------------------------------------
//
// An uncompressed CHD v5, which libchdr reads through the same track and hunk
// machinery a compressed one goes through — only the codec differs, and that is
// libchdr's own code rather than ours.

const int _sectorDataSize = 2352;
const int _frameSize = 2448;
const int _framesPerHunk = 8;
const int _hunkBytes = _frameSize * _framesPerHunk;

/// One track of a CHD under construction.
class ChdTrackSpec {
  final String type;
  final int frames;

  /// Frames of pregap. Stored in the file when [pregapType] says so, and
  /// generated by the drive otherwise.
  final int pregap;
  final String? pregapType;

  const ChdTrackSpec({
    required this.type,
    required this.frames,
    this.pregap = 0,
    this.pregapType,
  });
}

/// A raw mode 1 sector carrying [data].
Uint8List dataSector(List<int> data) {
  final raw = Uint8List(_sectorDataSize);
  raw[0] = 0x00;
  for (var i = 1; i <= 10; i++) {
    raw[i] = 0xFF;
  }
  raw[11] = 0x00;
  raw[15] = 1; // mode 1
  raw.setRange(16, 16 + data.length, data);
  return raw;
}

/// A raw mode 2 form 1 sector carrying [data], behind its subheader.
Uint8List mode2Sector(List<int> data) {
  final raw = Uint8List(_sectorDataSize);
  raw[0] = 0x00;
  for (var i = 1; i <= 10; i++) {
    raw[i] = 0xFF;
  }
  raw[11] = 0x00;
  raw[15] = 2; // mode 2
  raw.setRange(24, 24 + data.length, data);
  return raw;
}

/// Builds an uncompressed CHD holding [tracks], with [sectors] placed by their
/// physical frame within the image.
Uint8List buildChd({
  required List<ChdTrackSpec> tracks,
  Map<int, Uint8List> sectors = const {},
}) {
  var totalFrames = 0;
  for (final track in tracks) {
    totalFrames += track.frames + _padding(track.frames);
  }
  final hunkCount = (totalFrames + _framesPerHunk - 1) ~/ _framesPerHunk;

  // Hunks start one hunk in, because the map addresses them as multiples of the
  // hunk size and everything else has to fit before the first one.
  final dataStart = _hunkBytes;
  final bytes = Uint8List(dataStart + hunkCount * _hunkBytes);
  final view = ByteData.sublistView(bytes);

  // Metadata entries, chained, after the header.
  var offset = 124;
  final metaOffset = offset;
  for (var i = 0; i < tracks.length; i++) {
    final track = tracks[i];
    final text =
        'TRACK:${i + 1} TYPE:${track.type} SUBTYPE:NONE '
        'FRAMES:${track.frames} PREGAP:${track.pregap} '
        'PGTYPE:${track.pregapType ?? 'V'} PGSUB:RW POSTGAP:0';
    final data = Uint8List.fromList([...text.codeUnits, 0]);

    view.setUint32(offset, 0x43485432); // 'CHT2'
    view.setUint32(offset + 4, data.length);
    final next = offset + 16 + data.length;
    view.setUint64(offset + 8, i == tracks.length - 1 ? 0 : next);
    bytes.setRange(offset + 16, offset + 16 + data.length, data);
    offset = next;
  }

  final mapOffset = offset;
  for (var hunk = 0; hunk < hunkCount; hunk++) {
    // Each entry is the hunk's file offset, in hunks.
    view.setUint32(mapOffset + hunk * 4, hunk + 1);
  }

  // Header.
  bytes.setRange(0, 8, 'MComprHD'.codeUnits);
  view.setUint32(8, 124); // header length
  view.setUint32(12, 5); // version
  // Compressors all zero: uncompressed, which is what makes the map a plain
  // array of offsets.
  view.setUint64(32, hunkCount * _hunkBytes); // logical bytes
  view.setUint64(40, mapOffset);
  view.setUint64(48, metaOffset);
  view.setUint32(56, _hunkBytes);
  view.setUint32(60, _frameSize); // unit bytes

  sectors.forEach((frame, data) {
    final start = dataStart + frame * _frameSize;
    bytes.setRange(start, start + data.length, data);
  });

  return bytes;
}

int _padding(int frames) => (4 - (frames % 4)) % 4;
