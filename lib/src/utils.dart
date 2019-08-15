import 'dart:async';
import 'dart:convert' as cnv;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:process/process.dart';
import 'globals.dart';
import 'run.dart' as run;

/// Move files from [srcDir] to [dstDir].
///
/// If dstDir does not exist, it is created.
void moveFiles(String srcDir, String dstDir) {
  if (!Directory(dstDir).existsSync()) {
    Directory(dstDir).createSync(recursive: true);
  }
  Directory(srcDir).listSync().forEach((file) {
    file.renameSync('$dstDir/${p.basename(file.path)}');
  });
}

/// Execute command [cmd] with arguments [arguments] in a separate process
/// and stream stdout/stderr.
Future<void> streamCmd(String cmd, List<String> arguments,
    [String workingDirectory = '.',
    ProcessStartMode mode = ProcessStartMode.normal]) async {
//  print(
//      'streamCmd=\'$cmd ${arguments.join(" ")}\', workingDirectory=$workingDirectory, mode=$mode');

  final process = await Process.start(cmd, arguments,
      workingDirectory: workingDirectory, mode: mode);

  if (mode == ProcessStartMode.normal) {
    final stdoutFuture = process.stdout
        .transform(cnv.utf8.decoder)
        .transform(cnv.LineSplitter())
        .listen(stdout.writeln)
        .asFuture();
    final stderrFuture = process.stderr
        .transform(cnv.utf8.decoder)
        .transform(cnv.LineSplitter())
        .listen(stderr.writeln)
        .asFuture();
    await Future.wait([stdoutFuture, stderrFuture]);

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw 'command failed: exitcode=$exitCode, cmd=\'$cmd ${arguments.join(" ")}\', workingDirectory=$workingDirectory, mode=$mode';
    }
  }
}

/// Creates a list of available iOS simulators.
/// (really just concerned with simulators for now).
/// Provides access to their IDs and status'.
Map getIosSimulators() {
  final simulators =
      run.cmd('xcrun', ['simctl', 'list', 'devices', '--json'], '.', true);
  final simulatorsInfo = cnv.jsonDecode(simulators)['devices'];
  return transformIosSimulators(simulatorsInfo);
}

/// Transforms latest information about iOS simulators into more convenient
/// format to index into by simulator name.
/// (also useful for testing)
Map transformIosSimulators(Map simsInfo) {
  // transform json to a Map of device name by a map of iOS versions by a list of
  // devices with a map of properties
  // ie, Map<String, Map<String, List<Map<String, String>>>>
  // In other words, just pop-out the device name for 'easier' access to
  // the device properties.
  Map simsInfoTransformed = {};

  simsInfo.forEach((iOSName, sims) {
    // note: 'isAvailable' field does not appear consistently
    //       so using 'availability' as well
    isSimAvailable(sim) =>
        sim['availability'] == '(available)' || sim['isAvailable'] == true;
    for (final sim in sims) {
      // skip if simulator unavailable
      if (!isSimAvailable(sim)) continue;

      // init iOS versions map if not already present
      if (simsInfoTransformed[sim['name']] == null) {
        simsInfoTransformed[sim['name']] = {};
      }

      // init iOS version simulator array if not already present
      // note: there can be multiple versions of a simulator with the same name
      //       for an iOS version, hence the use of an array.
      if (simsInfoTransformed[sim['name']][iOSName] == null) {
        simsInfoTransformed[sim['name']][iOSName] = [];
      }

      // add simulator to iOS version simulator array
      simsInfoTransformed[sim['name']][iOSName].add(sim);
    }
  });
  return simsInfoTransformed;
}

// finds the iOS simulator with the highest available iOS version
Map getHighestIosSimulator(Map iosSims, String simName) {
  final Map iOSVersions = iosSims[simName];
  if (iOSVersions == null) return null; // todo: hack for real device

  // get highest iOS version
  var iOSVersionName = getHighestIosVersion(iOSVersions);

  final iosVersionSims = iosSims[simName][iOSVersionName];
  if (iosVersionSims.length == 0) {
    throw "Error: no simulators found for \'$simName\'";
  }
  // use the first device found for the iOS version
  return iosVersionSims[0];
}

// returns name of highest iOS version names
String getHighestIosVersion(Map iOSVersions) {
  // sort keys in iOS version order
  final iosVersionNames = iOSVersions.keys.toList();
//  print('keys=$iosVersionKeys');
  iosVersionNames.sort((v1, v2) {
    return v1.compareTo(v2);
  });
//  print('keys (sorted)=$iosVersionKeys');

  // get the highest iOS version
  final iOSVersionName = iosVersionNames.last;
  return iOSVersionName;
}

/// Create list of avds,
List<String> getAvdNames() {
  //return run.cmd('emulator', ['-list-avds'], '.', true).split('\n');
  return [];
}

/// Get the highest available avd version for the android emulator.
String getHighestAVD(String deviceName) {
  final emulatorName = deviceName.replaceAll(' ', '_');
  final avds =
      getAvdNames().where((name) => name.contains(emulatorName)).toList();
  // sort list in android API order
  avds.sort((v1, v2) {
    return v1.compareTo(v2);
  });

  return avds.last;
}

/// Adds prefix to all files in a directory
Future prefixFilesInDir(String dirPath, String prefix) async {
  await for (final file
      in Directory(dirPath).list(recursive: false, followLinks: false)) {
    await file
        .rename(p.dirname(file.path) + '/' + prefix + p.basename(file.path));
  }
}

/// Converts [enum] value to [String].
String getStringFromEnum(dynamic _enum) => _enum.toString().split('.').last;

/// Converts [String] to [enum].
T getEnumFromString<T>(List<T> values, String value) {
  return values.firstWhere((type) => getStringFromEnum(type) == value,
      orElse: () => null);
}

/// Returns locale of currently attached android device.
String getAndroidDeviceLocale(String deviceId) {
// ro.product.locale is available on first boot but does not update,
// persist.sys.locale is empty on first boot but updates with locale changes
  String locale = run
      .cmd('adb', ['-s', deviceId, 'shell', 'getprop persist.sys.locale'], '.',
          true)
      .trim();
  if (locale.isEmpty) {
    locale = run
        .cmd('adb', ['-s', deviceId, 'shell', 'getprop ro.product.locale'], '.',
            true)
        .trim();
  }
  return locale;
}

/// Returns locale of simulator with udid [udId].
String getIosSimulatorLocale(String udId) {
  final env = Platform.environment;
  final settingsPath =
      '${env['HOME']}/Library/Developer/CoreSimulator/Devices/$udId/data/Library/Preferences/.GlobalPreferences.plist';
  final localeInfo = cnv.jsonDecode(run.cmd(
      'plutil', ['-convert', 'json', '-o', '-', settingsPath], '.', true));
  final locale = localeInfo['AppleLocale'];
  return locale;
}

/// Get android emulator id from a running emulator with id [deviceId].
/// Returns emulator id as [String].
String getAndroidEmulatorId(String deviceId) {
  return run
      .cmd('adb', ['-s', deviceId, 'emu', 'avd', 'name'], '.', true)
      .split('\r\n')
      .map((line) => line.trim())
      .first;
}

/// Find android device id with matching [emulatorId].
/// Returns matching android device id as [String].
String findAndroidDeviceId(String emulatorId) {
  final devicesIds = getAndroidDeviceIds();
  if (devicesIds.isEmpty) return null;
  return devicesIds.firstWhere(
      (deviceId) => emulatorId == getAndroidEmulatorId(deviceId),
      orElse: () => null);
}

/// Get the list of running android devices by id.
List<String> getAndroidDeviceIds() {
  return run
      .cmd('adb', ['devices'], '.', true)
      .trim()
      .split('\n')
      .sublist(1) // remove first line
      .map((device) => device.split('\t').first)
      .toList();
}

/// Stop an android emulator.
Future stopAndroidEmulator(String deviceId, String stagingDir) async {
  run.cmd('adb', ['-s', deviceId, 'emu', 'kill']);
  // wait for emulator to stop
  await streamCmd(
      '$stagingDir/resources/script/android-wait-for-emulator-to-stop',
      [deviceId]);
}

/// Wait for android device/emulator locale to change.
Future<String> waitAndroidLocaleChange(String deviceId, String toLocale) async {
  final regExp = RegExp(
      'ContactsProvider: Locale has changed from .* to \\[${toLocale.replaceFirst('-', '_')}\\]|ContactsDatabaseHelper: Switching to locale \\[${toLocale.replaceFirst('-', '_')}\\]');
//  final regExp = RegExp(
//      'ContactsProvider: Locale has changed from .* to \\[${toLocale.replaceFirst('-', '_')}\\]');
//  final regExp = RegExp(
//      'ContactsProvider: Locale has changed from .* to \\[${toLocale.replaceFirst('-', '_')}\\]|ContactsDatabaseHelper: Locale change completed');
  final line =
      await waitSysLogMsg(deviceId, regExp, toLocale.replaceFirst('-', '_'));
  return line;
}

/// Filters a list of devices to get real ios devices.
List getIosDevices(List devices) {
  final iosDevices = devices
      .where((device) => device['platform'] == 'ios' && !device['emulator'])
      .toList();
  return iosDevices;
}

/// Filters a list of devices to get real android devices.
List getAndroidDevices(List devices) {
  final iosDevices = devices
      .where((device) => device['platform'] != 'ios' && !device['emulator'])
      .toList();
  return iosDevices;
}

/// Get all configured android and ios device names for this test run.
List getAllConfiguredDeviceNames(Map configInfo) {
  final androidDeviceNames = configInfo['devices']['android']?.keys ?? [];
  final iosDeviceNames = configInfo['devices']['ios']?.keys ?? [];
  final deviceNames = [...androidDeviceNames, ...iosDeviceNames];
  return deviceNames;
}

/// Get device for deviceName from list of devices.
Map getDevice(List devices, String deviceName) {
  return devices.firstWhere(
      (device) => device['model'] == null
          ? device['name'] == deviceName
          : device['model'].contains(deviceName),
      orElse: () => null);
}

/// Get device for deviceId from list of devices.
Map getDeviceFromId(List devices, String deviceId) {
  return devices.firstWhere((device) => device['id'] == deviceId,
      orElse: () => null);
}

/// Wait for message to appear in sys log and return first matching line
Future<String> waitSysLogMsg(
    String deviceId, RegExp regExp, String locale) async {
  run.cmd('adb', ['-s', deviceId, 'logcat', '-c']);
  await Future.delayed(Duration(milliseconds: 1000)); // wait for log to clear
  // -b main ContactsDatabaseHelper:I '*:S'
  final delegate = await Process.start('adb', [
    '-s',
    deviceId,
    'logcat',
    '-b',
    'main',
    '*:S',
    'ContactsDatabaseHelper:I',
    'ContactsProvider:I',
    '-e',
    locale
  ]);
  final process = ProcessWrapper(delegate);
  return await process.stdout
//      .transform<String>(cnv.Utf8Decoder(reportErrors: false)) // from flutter tools
      .transform<String>(cnv.Utf8Decoder(allowMalformed: true))
      .transform<String>(const cnv.LineSplitter())
      .firstWhere((line) {
    print(line);
    return regExp.hasMatch(line);
  }, orElse: () => null);
}

/// Find the emulator info of an named emulator available to boot.
Map findEmulator(List emulators, String emulatorName) {
  return emulators.firstWhere((emulator) => emulator['name'] == emulatorName,
      orElse: () => null);
}

/// Get [RunMode] from [String].
RunMode getRunModeEnum(String runMode) {
  return getEnumFromString<RunMode>(RunMode.values, runMode);
}

/// Test for recordings in [recordDir].
Future<bool> isRecorded(String recordDir) async =>
    !(await Directory(recordDir).list().isEmpty);

/// Test for CI environment.
bool isCI() {
  return Platform.environment['CI'] == 'true';
}
