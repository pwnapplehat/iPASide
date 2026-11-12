import 'dart:io';

import '../platform/windows_file_dialog.dart';

/// Native file dialogs for the things the app opens.
///
/// Abstracted so view models can be exercised without a desktop shell.
abstract class FilePickerService {
  /// Single `.ipa`; null when cancelled.
  Future<String?> pickIpa();

  /// One or more `.deb` / `.dylib` tweaks; empty when cancelled.
  Future<List<String>> pickTweaks();

  /// The folder to keep signed IPAs in; null when cancelled.
  Future<String?> pickSignedFolder();

  /// A pairing plist to import; null when cancelled.
  Future<String?> pickPairingFile();

  /// Where to write an exported pairing file; null when cancelled.
  Future<String?> savePairingFile({required String suggestedName});

  /// Where to write an unsigned IPA; null when cancelled.
  Future<String?> saveUnsignedIpa({required String suggestedName});
}

/// Shell-backed implementation.
///
/// On Windows this is `IFileOpenDialog` driven directly, which is what restores
/// the titles the previous build had. Everywhere else there is no dialog yet, so
/// every call reports a cancelled pick and a port only has to add its branch
/// here.
class NativeFilePickerService implements FilePickerService {
  const NativeFilePickerService();

  /// Titles carried over verbatim from the previous build.
  static const String ipaTitle = 'Choose an app to sideload';

  /// Title of the multi-select tweak dialog.
  static const String tweaksTitle = 'Add tweaks';

  /// Title of the folder dialog behind the Signed IPAs setting.
  static const String signedFolderTitle = 'Choose where to keep signed IPAs';

  /// Title of the dialog that picks an optional pairing plist from another tool.
  static const String pairingOpenTitle = 'Choose a pairing file';

  /// Title of the dialog that writes this PC's pairing file to disk.
  static const String pairingSaveTitle = 'Export pairing file';

  /// Title of the dialog that writes an unsigned, tweak-injected IPA.
  static const String unsignedIpaSaveTitle = 'Export unsigned IPA';

  /// Type dropdown for the IPA dialog.
  static const List<FileDialogFilter> ipaFilters = <FileDialogFilter>[
    FileDialogFilter(label: 'iOS app (*.ipa)', spec: '*.ipa'),
    FileDialogFilter.allFiles,
  ];

  /// Type dropdown for the tweak dialog. The engine resolves a `.deb` down to
  /// the dylibs inside it, so both extensions belong in one entry.
  static const List<FileDialogFilter> tweakFilters = <FileDialogFilter>[
    FileDialogFilter(label: 'Tweaks (*.deb;*.dylib)', spec: '*.deb;*.dylib'),
    FileDialogFilter.allFiles,
  ];

  /// Type dropdown for pairing files. EscapeOS and StikDebug use `.plist`;
  /// SideStore and AltStore use `.mobiledevicepairing`. Both are XML plists.
  static const List<FileDialogFilter> pairingFilters = <FileDialogFilter>[
    FileDialogFilter(
      label: 'Pairing file (*.plist;*.mobiledevicepairing)',
      spec: '*.plist;*.mobiledevicepairing',
    ),
    FileDialogFilter.allFiles,
  ];

  @override
  Future<String?> pickIpa() async {
    if (!Platform.isWindows) return null;
    await _letTheTapPaint();

    final List<String> chosen = WindowsFileDialog.open(
      title: ipaTitle,
      filters: ipaFilters,
    );
    return chosen.isEmpty ? null : chosen.first;
  }

  @override
  Future<List<String>> pickTweaks() async {
    if (!Platform.isWindows) return const <String>[];
    await _letTheTapPaint();

    return WindowsFileDialog.open(
      title: tweaksTitle,
      filters: tweakFilters,
      allowMultiple: true,
    );
  }

  @override
  Future<String?> pickSignedFolder() async {
    if (!Platform.isWindows) return null;
    await _letTheTapPaint();

    return WindowsFileDialog.openFolder(title: signedFolderTitle);
  }

  @override
  Future<String?> pickPairingFile() async {
    if (!Platform.isWindows) return null;
    await _letTheTapPaint();

    final List<String> chosen = WindowsFileDialog.open(
      title: pairingOpenTitle,
      filters: pairingFilters,
    );
    return chosen.isEmpty ? null : chosen.first;
  }

  @override
  Future<String?> savePairingFile({required String suggestedName}) async {
    if (!Platform.isWindows) return null;
    await _letTheTapPaint();

    return WindowsFileDialog.save(
      title: pairingSaveTitle,
      filters: pairingFilters,
      fileName: suggestedName,
      defaultExtension: 'plist',
    );
  }

  @override
  Future<String?> saveUnsignedIpa({required String suggestedName}) async {
    if (!Platform.isWindows) return null;
    await _letTheTapPaint();

    return WindowsFileDialog.save(
      title: unsignedIpaSaveTitle,
      filters: ipaFilters,
      fileName: suggestedName,
      defaultExtension: 'ipa',
    );
  }

  /// Yields once before blocking.
  ///
  /// The dialog runs its own message loop, so no frame is produced while it is
  /// up; without this the button or dropzone that opened it would still be
  /// drawn un-pressed underneath.
  static Future<void> _letTheTapPaint() => Future<void>.delayed(Duration.zero);
}
