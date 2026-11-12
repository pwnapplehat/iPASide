import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/platform/windows_file_dialog.dart';
import 'package:ipaside/services/file_picker.dart';

void main() {
  group('NativeFilePickerService dialog configuration', () {
    test('the titles are the ones the previous build showed', () {
      expect(NativeFilePickerService.ipaTitle, 'Choose an app to sideload');
      expect(NativeFilePickerService.tweaksTitle, 'Add tweaks');
    });

    test('the folder dialog says what the folder is for', () {
      expect(
        NativeFilePickerService.signedFolderTitle,
        'Choose where to keep signed IPAs',
      );
    });

    test('the IPA dialog offers the .ipa filter first, then all files', () {
      expect(NativeFilePickerService.ipaFilters, <FileDialogFilter>[
        const FileDialogFilter(label: 'iOS app (*.ipa)', spec: '*.ipa'),
        FileDialogFilter.allFiles,
      ]);
    });

    test('the tweak dialog matches .deb and .dylib in one entry', () {
      expect(NativeFilePickerService.tweakFilters, <FileDialogFilter>[
        const FileDialogFilter(
          label: 'Tweaks (*.deb;*.dylib)',
          spec: '*.deb;*.dylib',
        ),
        FileDialogFilter.allFiles,
      ]);
    });

    test('the pairing dialogs name both plist forms SideStore and EscapeOS use',
        () {
      expect(
        NativeFilePickerService.pairingOpenTitle,
        'Choose a pairing file',
      );
      expect(
        NativeFilePickerService.pairingSaveTitle,
        'Export pairing file',
      );
      expect(NativeFilePickerService.pairingFilters, <FileDialogFilter>[
        const FileDialogFilter(
          label: 'Pairing file (*.plist;*.mobiledevicepairing)',
          spec: '*.plist;*.mobiledevicepairing',
        ),
        FileDialogFilter.allFiles,
      ]);
    });

    test('every spec is a pattern list the shell can parse', () {
      final List<FileDialogFilter> all = <FileDialogFilter>[
        ...NativeFilePickerService.ipaFilters,
        ...NativeFilePickerService.tweakFilters,
        ...NativeFilePickerService.pairingFilters,
      ];

      for (final FileDialogFilter filter in all) {
        expect(filter.label, isNotEmpty);
        for (final String pattern in filter.spec.split(';')) {
          expect(
            pattern,
            matches(RegExp(r'^\*\.[A-Za-z*]+$')),
            reason: '${filter.label} has an unusable pattern',
          );
        }
      }
    });

    test('the label of each filter names the extensions it matches', () {
      // A dropdown entry that promises one thing and filters another is the
      // easiest way for these two constants to drift apart.
      for (final FileDialogFilter filter in <FileDialogFilter>[
        ...NativeFilePickerService.ipaFilters,
        ...NativeFilePickerService.tweakFilters,
        ...NativeFilePickerService.pairingFilters,
      ]) {
        for (final String pattern in filter.spec.split(';')) {
          expect(
            filter.label,
            contains(pattern.substring(1)),
            reason: '${filter.label} does not mention $pattern',
          );
        }
      }
    });
  });

  group(
    'Non-Windows fallback',
    // Calling these on Windows opens a real modal dialog and blocks until
    // somebody dismisses it, which a test run cannot do.
    skip: Platform.isWindows
        ? 'shows a real dialog on Windows; covered by a manual run'
        : null,
    () {
      test('pickIpa reports a cancelled pick where there is no dialog', () async {
        expect(await const NativeFilePickerService().pickIpa(), isNull);
      });

      test('pickTweaks reports no tweaks where there is no dialog', () async {
        expect(await const NativeFilePickerService().pickTweaks(), isEmpty);
      });

      test('pickSignedFolder reports a cancelled pick too', () async {
        expect(
          await const NativeFilePickerService().pickSignedFolder(),
          isNull,
        );
      });

      test('pickPairingFile reports a cancelled pick too', () async {
        expect(
          await const NativeFilePickerService().pickPairingFile(),
          isNull,
        );
      });

      test('savePairingFile reports a cancelled pick too', () async {
        expect(
          await const NativeFilePickerService().savePairingFile(
            suggestedName: 'pairingFile.plist',
          ),
          isNull,
        );
      });

      test('saveUnsignedIpa reports a cancelled pick too', () async {
        expect(
          await const NativeFilePickerService().saveUnsignedIpa(
            suggestedName: 'App.ipa',
          ),
          isNull,
        );
      });
    },
  );
}
