// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

// ignore: import_of_legacy_library_into_null_safe
import 'package:dwds/dwds.dart';
import 'package:package_config/package_config.dart';
import 'package:vm_service/vm_service.dart' as vmservice;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart'
    hide StackTrace;

import '../application_package.dart';
import '../base/async_guard.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../base/logger.dart';
import '../base/net.dart';
import '../base/terminal.dart';
import '../base/time.dart';
import '../base/utils.dart';
import '../build_info.dart';
import '../build_system/targets/web.dart';
import '../cache.dart';
import '../dart/language_version.dart';
import '../devfs.dart';
import '../device.dart';
import '../flutter_plugins.dart';
import '../project.dart';
import '../reporting/reporting.dart';
import '../resident_devtools_handler.dart';
import '../resident_runner.dart';
import '../run_hot.dart';
import '../vmservice.dart';
import '../web/chrome.dart';
import '../web/compile.dart';
import '../web/file_generators/main_dart.dart' as main_dart;
import '../web/web_device.dart';
import '../web/web_runner.dart';
import 'devfs_web.dart';

/// Injectable factory to create a [ResidentWebRunner].
class DwdsWebRunnerFactory extends WebRunnerFactory {
  @override
  ResidentRunner createWebRunner(
    FlutterDevice device, {
    String? target,
    required bool stayResident,
    required FlutterProject flutterProject,
    required bool? ipv6,
    required DebuggingOptions debuggingOptions,
    UrlTunneller? urlTunneller,
    required Logger logger,
    required FileSystem fileSystem,
    required SystemClock systemClock,
    required Usage usage,
    bool machine = false,
  }) {
    return ResidentWebRunner(
      device,
      target: target,
      flutterProject: flutterProject,
      debuggingOptions: debuggingOptions,
      ipv6: ipv6,
      stayResident: stayResident,
      urlTunneller: urlTunneller,
      machine: machine,
      usage: usage,
      systemClock: systemClock,
      fileSystem: fileSystem,
      logger: logger,
    );
  }
}

const String kExitMessage = 'Failed to establish connection with the application '
  'instance in Chrome.\nThis can happen if the websocket connection used by the '
  'web tooling is unable to correctly establish a connection, for example due to a firewall.';

class ResidentWebRunner extends ResidentRunner {
  ResidentWebRunner(
    FlutterDevice device, {
    String? target,
    bool stayResident = true,
    bool machine = false,
    required this.flutterProject,
    required bool? ipv6,
    required DebuggingOptions debuggingOptions,
    required FileSystem fileSystem,
    required Logger logger,
    required SystemClock systemClock,
    required Usage usage,
    UrlTunneller? urlTunneller,
    ResidentDevtoolsHandlerFactory devtoolsHandler = createDefaultHandler,
  }) : _fileSystem = fileSystem,
       _logger = logger,
       _systemClock = systemClock,
       _usage = usage,
       _urlTunneller = urlTunneller,
       super(
          <FlutterDevice>[device],
          target: target ?? fileSystem.path.join('lib', 'main.dart'),
          debuggingOptions: debuggingOptions,
          ipv6: ipv6,
          stayResident: stayResident,
          machine: machine,
          devtoolsHandler: devtoolsHandler,
        );

  final FileSystem _fileSystem;
  final Logger _logger;
  final SystemClock _systemClock;
  final Usage _usage;
  final UrlTunneller? _urlTunneller;

  @override
  Logger get logger => _logger;

  @override
  FileSystem get fileSystem => _fileSystem;

  FlutterDevice? get device => flutterDevices.first;
  final FlutterProject flutterProject;
  DateTime? firstBuildTime;

  // Used with the new compiler to generate a bootstrap file containing plugins
  // and platform initialization.
  Directory? _generatedEntrypointDirectory;

  // Only the debug builds of the web support the service protocol.
  @override
  bool get supportsServiceProtocol => isRunningDebug && deviceIsDebuggable;

  @override
  bool get debuggingEnabled => isRunningDebug && deviceIsDebuggable;

  /// WebServer device is debuggable when running with --start-paused.
  bool get deviceIsDebuggable => device!.device is! WebServerDevice || debuggingOptions.startPaused;

  @override
  bool get supportsWriteSkSL => false;

  @override
  // Web uses a different plugin registry.
  bool get generateDartPluginRegistry => false;

  bool get _enableDwds => debuggingEnabled;

  ConnectionResult? _connectionResult;
  StreamSubscription<vmservice.Event>? _stdOutSub;
  StreamSubscription<vmservice.Event>? _stdErrSub;
  StreamSubscription<vmservice.Event>? _extensionEventSub;
  bool _exited = false;
  WipConnection? _wipConnection;
  ChromiumLauncher? _chromiumLauncher;

  FlutterVmService get _vmService {
    if (_instance != null) {
      return _instance!;
    }
    final vmservice.VmService? service =_connectionResult?.vmService;
    final Uri websocketUri = Uri.parse(_connectionResult!.debugConnection!.uri);
    final Uri httpUri = _httpUriFromWebsocketUri(websocketUri);
    return _instance ??= FlutterVmService(service!, wsAddress: websocketUri, httpAddress: httpUri);
  }
  FlutterVmService? _instance;

  @override
  Future<void> cleanupAfterSignal() async {
    await _cleanup();
  }

  @override
  Future<void> cleanupAtFinish() async {
    await _cleanup();
  }

  Future<void> _cleanup() async {
    if (_exited) {
      return;
    }
    await residentDevtoolsHandler!.shutdown();
    await _stdOutSub?.cancel();
    await _stdErrSub?.cancel();
    await _extensionEventSub?.cancel();
    await device!.device!.stopApp(null);
    try {
      _generatedEntrypointDirectory?.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort to clean up temp dirs.
      _logger.printTrace(
        'Failed to clean up temp directory: ${_generatedEntrypointDirectory!.path}',
      );
    }
    _exited = true;
  }

  Future<void> _cleanupAndExit() async {
    await _cleanup();
    appFinished();
  }

  @override
  void printHelp({bool details = true}) {
    if (details) {
      return printHelpDetails();
    }
    const String fire = '🔥';
    const String rawMessage =
        '  To hot restart changes while running, press "r" or "R".';
    final String message = _logger.terminal.color(
      fire + _logger.terminal.bolden(rawMessage),
      TerminalColor.red,
    );
    _logger.printStatus(message);
    const String quitMessage = 'To quit, press "q".';
    _logger.printStatus('For a more detailed help message, press "h". $quitMessage');
    _logger.printStatus('');
    printDebuggerList();
  }

  @override
  Future<void> stopEchoingDeviceLog() async {
    // Do nothing for ResidentWebRunner
    await device!.stopEchoingDeviceLog();
  }

  @override
  Future<int> run({
    Completer<DebugConnectionInfo>? connectionInfoCompleter,
    Completer<void>? appStartedCompleter,
    bool enableDevTools = false, // ignored, we don't yet support devtools for web
    String? route,
  }) async {
    firstBuildTime = DateTime.now();
    final ApplicationPackage? package = await ApplicationPackageFactory.instance!.getPackageForPlatform(
      TargetPlatform.web_javascript,
      buildInfo: debuggingOptions.buildInfo,
    );
    if (package == null) {
      _logger.printStatus('This application is not configured to build on the web.');
      _logger.printStatus('To add web support to a project, run `flutter create .`.');
    }
    final String modeName = debuggingOptions.buildInfo.friendlyModeName;
    _logger.printStatus(
      'Launching ${getDisplayPath(target, _fileSystem)} '
      'on ${device!.device!.name} in $modeName mode...',
    );
    if (device!.device is ChromiumDevice) {
      _chromiumLauncher = (device!.device! as ChromiumDevice).chromeLauncher;
    }

    try {
      return await asyncGuard(() async {
        final ExpressionCompiler? expressionCompiler =
          debuggingOptions.webEnableExpressionEvaluation
              ? WebExpressionCompiler(device!.generator!, fileSystem: _fileSystem)
              : null;
        device!.devFS = WebDevFS(
          hostname: debuggingOptions.hostname ?? 'localhost',
          port: debuggingOptions.port != null
            ? int.tryParse(debuggingOptions.port!)
            : null,
          packagesFilePath: packagesFilePath,
          urlTunneller: _urlTunneller,
          useSseForDebugProxy: debuggingOptions.webUseSseForDebugProxy,
          useSseForDebugBackend: debuggingOptions.webUseSseForDebugBackend,
          useSseForInjectedClient: debuggingOptions.webUseSseForInjectedClient,
          buildInfo: debuggingOptions.buildInfo,
          enableDwds: _enableDwds,
          enableDds: debuggingOptions.enableDds,
          entrypoint: _fileSystem.file(target).uri,
          expressionCompiler: expressionCompiler,
          chromiumLauncher: _chromiumLauncher,
          nullAssertions: debuggingOptions.nullAssertions,
          nullSafetyMode: debuggingOptions.buildInfo.nullSafetyMode,
          nativeNullAssertions: debuggingOptions.nativeNullAssertions,
        );
        final Uri url = await device!.devFS!.create();
        if (debuggingOptions.buildInfo.isDebug) {
          await runSourceGenerators();
          final UpdateFSReport report = await _updateDevFS(fullRestart: true);
          if (!report.success) {
            _logger.printError('Failed to compile application.');
            appFailedToStart();
            return 1;
          }
          device!.generator!.accept();
          cacheInitialDillCompilation();
        } else {
          await buildWeb(
            flutterProject,
            target,
            debuggingOptions.buildInfo,
            false,
            kNoneWorker,
            true,
            debuggingOptions.nativeNullAssertions,
          );
        }
        await device!.device!.startApp(
          package,
          mainPath: target,
          debuggingOptions: debuggingOptions,
          platformArgs: <String, Object>{
            'uri': url.toString(),
          },
        );
        return attach(
          connectionInfoCompleter: connectionInfoCompleter,
          appStartedCompleter: appStartedCompleter,
          enableDevTools: enableDevTools,
        );
      });
    } on WebSocketException catch (error, stackTrace) {
      appFailedToStart();
      _logger.printError('$error', stackTrace: stackTrace);
      throwToolExit(kExitMessage);
    } on ChromeDebugException catch (error, stackTrace) {
      appFailedToStart();
      _logger.printError('$error', stackTrace: stackTrace);
      throwToolExit(kExitMessage);
    } on AppConnectionException catch (error, stackTrace) {
      appFailedToStart();
      _logger.printError('$error', stackTrace: stackTrace);
      throwToolExit(kExitMessage);
    } on SocketException catch (error, stackTrace) {
      appFailedToStart();
      _logger.printError('$error', stackTrace: stackTrace);
      throwToolExit(kExitMessage);
    } on Exception {
      appFailedToStart();
      rethrow;
    }
  }

  @override
  Future<OperationResult> restart({
    bool fullRestart = false,
    bool? pause = false,
    String? reason,
    bool benchmarkMode = false,
  }) async {
    final DateTime start = _systemClock.now();
    final Status status = _logger.startProgress(
      'Performing hot restart...',
      progressId: 'hot.restart',
    );

    if (debuggingOptions.buildInfo.isDebug) {
      await runSourceGenerators();
      // Full restart is always false for web, since the extra recompile is wasteful.
      final UpdateFSReport report = await _updateDevFS();
      if (report.success) {
        device!.generator!.accept();
      } else {
        status.stop();
        await device!.generator!.reject();
        return OperationResult(1, 'Failed to recompile application.');
      }
    } else {
      try {
        await buildWeb(
          flutterProject,
          target,
          debuggingOptions.buildInfo,
          false,
          kNoneWorker,
          true,
          debuggingOptions.nativeNullAssertions,
          baseHref: kBaseHref,
        );
      } on ToolExit {
        return OperationResult(1, 'Failed to recompile application.');
      }
    }

    try {
      if (!deviceIsDebuggable) {
        _logger.printStatus('Recompile complete. Page requires refresh.');
      } else if (isRunningDebug) {
        await _vmService.service.callMethod('hotRestart');
      } else {
        // On non-debug builds, a hard refresh is required to ensure the
        // up to date sources are loaded.
        await _wipConnection?.sendCommand('Page.reload', <String, Object>{
          'ignoreCache': !debuggingOptions.buildInfo.isDebug,
        });
      }
    } on Exception catch (err) {
      return OperationResult(1, err.toString(), fatal: true);
    } finally {
      status.stop();
    }

    final Duration elapsed = _systemClock.now().difference(start);
    final String elapsedMS = getElapsedAsMilliseconds(elapsed);
    _logger.printStatus('Restarted application in $elapsedMS.');
    unawaited(residentDevtoolsHandler!.hotRestart(flutterDevices));

    // Don't track restart times for dart2js builds or web-server devices.
    if (debuggingOptions.buildInfo.isDebug && deviceIsDebuggable) {
      _usage.sendTiming('hot', 'web-incremental-restart', elapsed);
      HotEvent(
        'restart',
        targetPlatform: getNameForTargetPlatform(TargetPlatform.web_javascript),
        sdkName: await device!.device!.sdkNameAndVersion,
        emulator: false,
        fullRestart: true,
        reason: reason,
        overallTimeInMs: elapsed.inMilliseconds,
        fastReassemble: false,
      ).send();
    }
    return OperationResult.ok;
  }

  // Flutter web projects need to include a generated main entrypoint to call the
  // appropriate bootstrap method and inject plugins.
  // Keep this in sync with build_system/targets/web.dart.
  Future<Uri> _generateEntrypoint(Uri mainUri, PackageConfig? packageConfig) async {
    File? result = _generatedEntrypointDirectory?.childFile('web_entrypoint.dart');
    if (_generatedEntrypointDirectory == null) {
      _generatedEntrypointDirectory ??= _fileSystem.systemTempDirectory.createTempSync('flutter_tools.')
        ..createSync();
      result = _generatedEntrypointDirectory!.childFile('web_entrypoint.dart');

      // Generates the generated_plugin_registrar
      await injectBuildTimePluginFiles(flutterProject, webPlatform: true, destination: _generatedEntrypointDirectory!);
      // The below works because `injectBuildTimePluginFiles` is configured to write
      // the web_plugin_registrant.dart file alongside the generated main.dart
      const String generatedImport = 'web_plugin_registrant.dart';

      Uri? importedEntrypoint = packageConfig!.toPackageUri(mainUri);
      // Special handling for entrypoints that are not under lib, such as test scripts.
      if (importedEntrypoint == null) {
        final String parent = _fileSystem.file(mainUri).parent.path;
        flutterDevices.first.generator!
          ..addFileSystemRoot(parent)
          ..addFileSystemRoot(_fileSystem.directory('test').absolute.path);
        importedEntrypoint = Uri(
          scheme: 'org-dartlang-app',
          path: '/${mainUri.pathSegments.last}',
        );
      }
      final LanguageVersion languageVersion = determineLanguageVersion(
        _fileSystem.file(mainUri),
        packageConfig[flutterProject.manifest.appName],
        Cache.flutterRoot!,
      );

      final String entrypoint = main_dart.generateMainDartFile(importedEntrypoint.toString(),
        languageVersion: languageVersion,
        pluginRegistrantEntrypoint: generatedImport,
      );

      result.writeAsStringSync(entrypoint);
    }
    return result!.absolute.uri;
  }

  Future<UpdateFSReport> _updateDevFS({bool fullRestart = false}) async {
    final bool isFirstUpload = !assetBundle.wasBuiltOnce();
    final bool rebuildBundle = assetBundle.needsBuild();
    if (rebuildBundle) {
      _logger.printTrace('Updating assets');
      final int result = await assetBundle.build(
        packagesPath: debuggingOptions.buildInfo.packagesPath,
        targetPlatform: TargetPlatform.web_javascript,
      );
      if (result != 0) {
        return UpdateFSReport();
      }
    }
    final InvalidationResult invalidationResult = await projectFileInvalidator.findInvalidated(
      lastCompiled: device!.devFS!.lastCompiled,
      urisToMonitor: device!.devFS!.sources,
      packagesPath: packagesFilePath,
      packageConfig: device!.devFS!.lastPackageConfig
        ?? debuggingOptions.buildInfo.packageConfig,
    );
    final Status devFSStatus = _logger.startProgress(
      'Waiting for connection from debug service on ${device!.device!.name}...',
    );
    final UpdateFSReport report = await device!.devFS!.update(
      mainUri: await _generateEntrypoint(
        _fileSystem.file(mainPath).absolute.uri,
        invalidationResult.packageConfig,
      ),
      target: target,
      bundle: assetBundle,
      firstBuildTime: firstBuildTime,
      bundleFirstUpload: isFirstUpload,
      generator: device!.generator!,
      fullRestart: fullRestart,
      dillOutputPath: dillOutputPath,
      projectRootPath: projectRootPath,
      pathToReload: getReloadPath(fullRestart: fullRestart, swap: false),
      invalidatedFiles: invalidationResult.uris!,
      packageConfig: invalidationResult.packageConfig!,
      trackWidgetCreation: debuggingOptions.buildInfo.trackWidgetCreation,
      shaderCompiler: device!.developmentShaderCompiler,
    );
    devFSStatus.stop();
    _logger.printTrace('Synced ${getSizeAsMB(report.syncedBytes)}.');
    return report;
  }

  @override
  Future<int> attach({
    Completer<DebugConnectionInfo>? connectionInfoCompleter,
    Completer<void>? appStartedCompleter,
    bool allowExistingDdsInstance = false,
    bool enableDevTools = false, // ignored, we don't yet support devtools for web
    bool needsFullRestart = true,
  }) async {
    if (_chromiumLauncher != null) {
      final Chromium chrome = await _chromiumLauncher!.connectedInstance;
      final ChromeTab? chromeTab = await chrome.chromeConnection.getTab((ChromeTab chromeTab) {
        return !chromeTab.url.startsWith('chrome-extension');
      }, retryFor: const Duration(seconds: 5));
      if (chromeTab == null) {
        throwToolExit('Failed to connect to Chrome instance.');
      }
      _wipConnection = await chromeTab.connect();
    }
    Uri? websocketUri;
    if (supportsServiceProtocol) {
      final WebDevFS webDevFS = device!.devFS! as WebDevFS;
      final bool useDebugExtension = device!.device is WebServerDevice && debuggingOptions.startPaused;
      _connectionResult = await webDevFS.connect(useDebugExtension);
      unawaited(_connectionResult!.debugConnection!.onDone.whenComplete(_cleanupAndExit));

      void onLogEvent(vmservice.Event event)  {
        final String message = processVmServiceMessage(event);
        _logger.printStatus(message);
      }

      _stdOutSub = _vmService.service.onStdoutEvent.listen(onLogEvent);
      _stdErrSub = _vmService.service.onStderrEvent.listen(onLogEvent);
      try {
        await _vmService.service.streamListen(vmservice.EventStreams.kStdout);
      } on vmservice.RPCError {
        // It is safe to ignore this error because we expect an error to be
        // thrown if we're not already subscribed.
      }
      try {
        await _vmService.service.streamListen(vmservice.EventStreams.kStderr);
      } on vmservice.RPCError {
        // It is safe to ignore this error because we expect an error to be
        // thrown if we're not already subscribed.
      }
      try {
        await _vmService.service.streamListen(vmservice.EventStreams.kIsolate);
      } on vmservice.RPCError {
        // It is safe to ignore this error because we expect an error to be
        // thrown if we're not already subscribed.
      }
      await setUpVmService(
        (String isolateId, {
          bool? force,
          bool? pause,
        }) async {
          await restart(pause: pause);
        },
        null,
        null,
        device!.device,
        null,
        printStructuredErrorLog,
        _vmService.service,
      );


      websocketUri = Uri.parse(_connectionResult!.debugConnection!.uri);
      device!.vmService = _vmService;

      // Run main immediately if the app is not started paused or if there
      // is no debugger attached. Otherwise, runMain when a resume event
      // is received.
      if (!debuggingOptions.startPaused || !supportsServiceProtocol) {
        _connectionResult!.appConnection!.runMain();
      } else {
        late StreamSubscription<void> resumeSub;
        resumeSub = _vmService.service.onDebugEvent
            .listen((vmservice.Event event) {
          if (event.type == vmservice.EventKind.kResume) {
            _connectionResult!.appConnection!.runMain();
            resumeSub.cancel();
          }
        });
      }
      if (enableDevTools) {
        // The method below is guaranteed never to return a failing future.
        unawaited(residentDevtoolsHandler!.serveAndAnnounceDevTools(
          devToolsServerAddress: debuggingOptions.devToolsServerAddress,
          flutterDevices: flutterDevices,
        ));
      }
    }
    if (websocketUri != null) {
      if (debuggingOptions.vmserviceOutFile != null) {
        _fileSystem.file(debuggingOptions.vmserviceOutFile)
          ..createSync(recursive: true)
          ..writeAsStringSync(websocketUri.toString());
      }
      _logger.printStatus('Debug service listening on $websocketUri');
      _logger.printStatus('');
      if (debuggingOptions.buildInfo.nullSafetyMode ==  NullSafetyMode.sound) {
        _logger.printStatus('💪 Running with sound null safety 💪', emphasis: true);
      } else {
        _logger.printStatus(
          'Running without sound null safety ⚠️',
          emphasis: true,
        );
        _logger.printStatus(
          'Dart 3 will only support sound null safety, see https://dart.dev/null-safety',
        );
      }
    }
    appStartedCompleter?.complete();
    connectionInfoCompleter?.complete(DebugConnectionInfo(wsUri: websocketUri));
    if (stayResident) {
      await waitForAppToFinish();
    } else {
      await stopEchoingDeviceLog();
      await exitApp();
    }
    await cleanupAtFinish();
    return 0;
  }

  @override
  Future<void> exitApp() async {
    await device!.exitApps();
    appFinished();
  }
}

Uri _httpUriFromWebsocketUri(Uri websocketUri) {
  const String wsPath = '/ws';
  final String path = websocketUri.path;
  return websocketUri.replace(scheme: 'http', path: path.substring(0, path.length - wsPath.length));
}
