import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as path;
import 'package:recase/recase.dart';

import '../constants.dart';


// =============================================================================
// 1. Core Command (The Entry Point)
// =============================================================================

class SvgToFontCommand extends Command<int> {
  SvgToFontCommand() {
    argParser
      ..addOption(svgInputDir, abbr: 'i', help: 'Input path of SVG files', mandatory: true)
      ..addOption(fontOutputDir, abbr: 'o', help: 'Output path for .ttf fonts', mandatory: true)
      ..addOption(iconsOutputDir, abbr: 'c', help: 'Output path for Dart class', mandatory: true)
      ..addOption(iconsClassName, abbr: 'n', defaultsTo: defaultIconsClassName, help: 'Class name for icons')
      ..addOption(iconsPackageName, abbr: 'p', help: 'Package name (if generating for a package)')
      ..addFlag(deleteInput, defaultsTo: false, help: 'Delete input SVGs after generation')
      ..addFlag(useColor, defaultsTo: false, help: 'Enable colored icon generation (Requires Python/Nanoemoji)')
      ..addFlag(verbose, abbr: 'v', defaultsTo: false, help: 'Show detailed logs')
      ..addFlag(keepTemp, defaultsTo: false, help: 'Keep temporary files for debugging');
  }

  @override
  String get name => 'generate';

  @override
  String get description => 'Generates font files and Flutter Icon classes from SVGs.';

  @override
  Future<int> run() async {
    final bool isVerbose = argResults![verbose];
    final bool shouldKeepTemp = argResults![keepTemp];
    final logger = Logger(verbose: isVerbose);
    final shell = ShellExecutor(logger);

    Directory? workspaceDir;

    try {
      logger.info('🚀 Starting SvgToFont generation...');

      // 1. Setup Workspace (Use System Temp, never package root)
      workspaceDir = Directory.systemTemp.createTempSync('svg_to_font_build_');
      logger.debug('Workspace created at: ${workspaceDir.path}');

      // 2. Parse Inputs
      final inputDir = Directory(argResults![svgInputDir]);
      final fontOutDir = Directory(argResults![fontOutputDir]);
      final iconsOutDir = Directory(argResults![iconsOutputDir]);
      final className = argResults![iconsClassName];
      final packageName = argResults![iconsPackageName];
      final isColor = argResults![useColor];

      if (!inputDir.existsSync()) {
        throw ToolException('Input directory does not exist: ${inputDir.path}');
      }

      // 3. Normalize SVGs
      final processor = SvgProcessor(logger, workspaceDir);
      final processingResult = await processor.prepareSvgs(inputDir);

      if (processingResult.files.isEmpty) {
        throw ToolException('No SVG files found in ${inputDir.path}');
      }

      // 4. Select Strategy & Generate Font
      final FontGenerator generator = isColor
          ? NanoEmojiGenerator(shell, logger, workspaceDir)
          : FantasticonGenerator(shell, logger, workspaceDir);

      logger.info('🛠  Checking prerequisites for ${isColor ? "Color" : "Mono"} mode...');
      await generator.checkPrerequisites();

      logger.info('⚙️  Generating font...');
      final generationResult = await generator.generate(
        processingResult.files,
        className,
      );

      // 5. Generate Flutter Code
      logger.info('📝 Generating Dart code...');
      final codeGenerator = DartClassGenerator();
      final dartCode = codeGenerator.generate(
        className: className,
        packageName: packageName,
        glyphMap: generationResult.glyphMap,
        originalFileMap: processingResult.originalPathMap,
      );

      // 6. Delivery (Move artifacts from Temp to User Output)
      await _deliverArtifacts(
        fontFile: generationResult.fontFile,
        dartContent: dartCode,
        fontOutputDir: fontOutDir,
        iconsOutputDir: iconsOutDir,
        className: className,
        logger: logger,
      );

      // 7. Cleanup Input (Optional)
      if (argResults![deleteInput]) {
        logger.info('🗑  Deleting source SVGs...');
        await inputDir.delete(recursive: true);
      }

      logger.success('✅ Generation complete!');
      return 0;

    } on ToolException catch (e) {
      logger.error(e.message);
      return 1;
    } catch (e, stack) {
      logger.error('Unexpected error: $e');
      if (isVerbose) logger.error(stack.toString());
      return 1;
    } finally {
      // Always clean up temp workspace unless keep-temp is true
      if (workspaceDir != null && workspaceDir.existsSync()) {
        if (shouldKeepTemp) {
          logger.info('ℹ️  Keeping temp workspace at: ${workspaceDir.path}');
        } else {
          try {
            workspaceDir.deleteSync(recursive: true);
            logger.debug('Workspace cleaned up.');
          } catch (e) {
            logger.debug('Failed to clean workspace: $e');
          }
        }
      }
    }
  }

  Future<void> _deliverArtifacts({
    required File fontFile,
    required String dartContent,
    required Directory fontOutputDir,
    required Directory iconsOutputDir,
    required String className,
    required Logger logger,
  }) async {
    if (!fontOutputDir.existsSync()) await fontOutputDir.create(recursive: true);
    if (!iconsOutputDir.existsSync()) await iconsOutputDir.create(recursive: true);

    // Copy Font
    final targetFontPath = path.join(fontOutputDir.path, '$className.ttf');
    await fontFile.copy(targetFontPath);
    logger.info('Checking out font: $targetFontPath');

    // Write Dart Class
    final targetDartPath = path.join(iconsOutputDir.path, '${ReCase(className).snakeCase}.dart');
    await File(targetDartPath).writeAsString(dartContent);
    logger.info('Checking out code: $targetDartPath');
  }
}

// =============================================================================
// 2. Domain Logic: Font Generators (Strategy Pattern)
// =============================================================================

class FontGenerationResult {
  final File fontFile;
  final Map<String, int> glyphMap;

  FontGenerationResult(this.fontFile, this.glyphMap);
}

abstract class FontGenerator {
  final ShellExecutor shell;
  final Logger logger;
  final Directory workspace;

  FontGenerator(this.shell, this.logger, this.workspace);

  Future<void> checkPrerequisites();
  Future<FontGenerationResult> generate(List<File> svgs, String className);
}

/// Generates Monotone fonts using Node.js + Fantasticon
class FantasticonGenerator extends FontGenerator {
  FantasticonGenerator(super.shell, super.logger, super.workspace);

  @override
  Future<void> checkPrerequisites() async {
    try {
      await shell.execute('node', ['--version']);
      await shell.execute('npm', ['--version']);
    } catch (e) {
      throw ToolException('NodeJS and NPM are required. Please install them.');
    }
  }

  @override
  Future<FontGenerationResult> generate(List<File> svgs, String className) async {
    // 1. Initialize simple package.json in temp workspace
    final packageJson = File(path.join(workspace.path, 'package.json'));
    await packageJson.writeAsString('{"name": "temp_font_gen", "private": true}');

    // 2. Install fantasticon locally in workspace (avoids global pollution)
    logger.info('Installing fantasticon in temporary workspace...');
    await shell.execute('npm', ['install', 'fantasticon'], workingDirectory: workspace.path);

    // 3. Run Fantasticon
    final inputDir = Directory(path.join(workspace.path, 'icons'));
    if (!inputDir.existsSync()) inputDir.createSync();

    // Copy SVGs to input dir (Fantasticon needs a dir)
    for (var f in svgs) {
      await f.copy(path.join(inputDir.path, path.basename(f.path)));
    }

    final outputDir = Directory(path.join(workspace.path, 'out'));
    if (!outputDir.existsSync()) outputDir.createSync();

    final configFile = File(path.join(workspace.path, 'fantasticonrc.json'));
    // CRITICAL FIX: Use 'outputDir' instead of 'output' in config JSON.
    await configFile.writeAsString(jsonEncode({
      'name': className,
      'outputDir': outputDir.path, // <--- Fixed key
      'inputDir': inputDir.path,
      'fontTypes': ['ttf'],
      'assetTypes': ['json'],
      'formatOptions': {'json': {'indent': 2}}
    }));

    // CRITICAL FIX: Removed inputDir.path positional arg, relying on config file 'inputDir'
    await shell.execute(
      path.join(workspace.path, 'node_modules', '.bin', 'fantasticon'),
      ['-c', configFile.path],
      workingDirectory: workspace.path,
    );

    // 4. Parse Result
    final ttf = File(path.join(outputDir.path, '$className.ttf'));
    final mapFile = File(path.join(outputDir.path, '$className.json'));

    if (!ttf.existsSync() || !mapFile.existsSync()) {
      throw ToolException('Fantasticon failed to produce output files.');
    }

    final Map<String, dynamic> rawMap = jsonDecode(await mapFile.readAsString());
    final Map<String, int> glyphMap = rawMap.map((key, value) => MapEntry(key, value as int));

    return FontGenerationResult(ttf, glyphMap);
  }
}

/// Generates Color fonts using Python + NanoEmoji
class NanoEmojiGenerator extends FontGenerator {
  NanoEmojiGenerator(super.shell, super.logger, super.workspace);

  @override
  Future<void> checkPrerequisites() async {
    try {
      await shell.execute('python3', ['--version']);
    } catch (e) {
      throw ToolException('Python 3 is required for color fonts.');
    }
  }

  @override
  Future<FontGenerationResult> generate(List<File> svgs, String className) async {
    // 1. Setup Virtual Env in workspace
    final venvPath = path.join(workspace.path, 'venv');
    logger.info('Creating Python virtual environment...');
    await shell.execute('python3', ['-m', 'venv', venvPath]);

    final pipPath = path.join(venvPath, 'bin', 'pip');
    final nanoPath = path.join(venvPath, 'bin', 'nanoemoji');

    // 2. Install nanoemoji
    logger.info('Installing nanoemoji (this may take a moment)...');
    await shell.execute(pipPath, ['install', 'nanoemoji', 'ninja'], workingDirectory: workspace.path);

    // 3. Prepare Files with PUA Codepoints
    // Nanoemoji infers codepoints from filenames if formatted like uE001.svg
    // We construct a deterministic map here.
    final preparedDir = Directory(path.join(workspace.path, 'prepared_icons'));
    preparedDir.createSync();

    final Map<String, int> glyphMap = {};
    int currentCodePoint = 0xE000;
    final List<String> fileArgs = [];

    // Sort to ensure deterministic assignment
    svgs.sort((a, b) => path.basename(a.path).compareTo(path.basename(b.path)));

    for (var file in svgs) {
      final name = path.basenameWithoutExtension(file.path);
      final ext = path.extension(file.path);
      final hexCode = currentCodePoint.toRadixString(16).toUpperCase();

      // Filename format: icon_name_uE000.svg
      final newName = '${name}_u$hexCode$ext';
      final newPath = path.join(preparedDir.path, newName);

      await file.copy(newPath);

      glyphMap[name] = currentCodePoint;
      fileArgs.add(newPath);
      currentCodePoint++;
    }

    // 4. Run Nanoemoji
    final outputFile = path.join(workspace.path, '$className.ttf');

    // We must add venv/bin to path for ninja to work
    final env = {
      'PATH': '${path.join(venvPath, 'bin')}:${Platform.environment['PATH'] ?? ''}'
    };

    logger.info('Running nanoemoji...');
    await shell.execute(
        nanoPath,
        ['--output_file', outputFile, ...fileArgs],
        environment: env,
        workingDirectory: workspace.path
    );

    final ttf = File(outputFile);
    if (!ttf.existsSync()) {
      throw ToolException('Nanoemoji failed to generate TTF.');
    }

    // For color fonts, we use our pre-calculated map,
    // because extracting from COLR tables is painful and brittle.
    return FontGenerationResult(ttf, glyphMap);
  }
}

// =============================================================================
// 3. Utilities: Processing, Generation, & Execution
// =============================================================================

class SvgProcessingResult {
  final List<File> files;
  /// Maps 'icon_name' -> '/original/path/to/icon_name.svg' (for comments)
  final Map<String, String> originalPathMap;
  SvgProcessingResult(this.files, this.originalPathMap);
}

class SvgProcessor {
  final Logger logger;
  final Directory workspace;

  SvgProcessor(this.logger, this.workspace);

  Future<SvgProcessingResult> prepareSvgs(Directory inputDir) async {
    final List<File> validFiles = [];
    final Map<String, String> originalPaths = {};
    final processingDir = Directory(path.join(workspace.path, 'raw_icons'));
    processingDir.createSync();

    await for (final entity in inputDir.list(recursive: true)) {
      if (entity is File) {
        final ext = path.extension(entity.path).toLowerCase();
        if (ext == '.svg' || ext == '.png') {
          final baseName = path.basenameWithoutExtension(entity.path);
          // Sanitize filename for tool compatibility
          final safeName = ReCase(baseName).snakeCase;

          final dest = File(path.join(processingDir.path, '$safeName$ext'));
          await entity.copy(dest.path);

          validFiles.add(dest);
          originalPaths[safeName] = entity.path;
        }
      }
    }
    return SvgProcessingResult(validFiles, originalPaths);
  }
}

class DartClassGenerator {
  String generate({
    required String className,
    required String? packageName,
    required Map<String, int> glyphMap,
    required Map<String, String> originalFileMap,
  }) {
    final library = Library((b) => b
      ..directives.add(Directive.import('package:flutter/widgets.dart'))
      ..body.add(Class((c) => c
        ..name = className
        ..abstract = true
        ..docs.add('/// Generated by SvgToFont')
        ..constructors.add(Constructor((c) => c..name = '_'))
        ..fields.add(Field((f) => f
          ..name = 'fontFamily'
          ..static = true
          ..modifier = FieldModifier.constant
          ..type = refer('String')
          ..assignment = literalString(className).code
        ))
        ..fields.add(Field((f) => f
          ..name = 'fontPackage'
          ..static = true
          ..modifier = FieldModifier.constant
          ..type = refer('String?')
          ..assignment = packageName != null ? literalString(packageName).code : literalNull.code
        ))
        ..fields.addAll(_buildIconFields(glyphMap, originalFileMap))
        ..fields.add(_buildAllField(glyphMap))
      ))
    );

    final emitter = DartEmitter(
      allocator: Allocator.simplePrefixing(),
      orderDirectives: true,
      useNullSafetySyntax: true,
    );

    return DartFormatter(languageVersion: DartFormatter.latestLanguageVersion).format('${library.accept(emitter)}');
  }

  Iterable<Field> _buildIconFields(Map<String, int> glyphs, Map<String, String> originalPaths) {
    return glyphs.entries.map((e) {
      final sanitizedName = _sanitizeIdentifier(e.key);
      final originalPath = originalPaths[e.key] ?? 'unknown';

      return Field((f) => f
        ..name = sanitizedName
        ..static = true
        ..modifier = FieldModifier.constant
        ..type = refer('IconData')
        ..docs.add('/// File: $originalPath')
        ..assignment = refer('IconData').call([
          // Use CodeExpression to force hex format instead of literalNum(e.value)
          CodeExpression(Code('0x${e.value.toRadixString(16)}')),
        ], {
          'fontFamily': refer('fontFamily'),
          'fontPackage': refer('fontPackage'),
        }).code
      );
    });
  }

  Field _buildAllField(Map<String, int> glyphs) {
    final mapContent = <Object, Object>{};
    for (final key in glyphs.keys) {
      final sanitized = _sanitizeIdentifier(key);
      mapContent[sanitized] = refer(sanitized);
    }

    return Field((f) => f
      ..name = 'all'
      ..static = true
      ..modifier = FieldModifier.constant
      ..type = refer('Map<String, IconData>')
      ..assignment = literalMap(mapContent, refer('String'), refer('IconData')).code
    );
  }

  String _sanitizeIdentifier(String name) {
    String safe = ReCase(name).snakeCase;
    // Handle reserved keywords or invalid starts
    if (RegExp(r'^[0-9]').hasMatch(safe) || _dartKeywords.contains(safe)) {
      return 'icon_$safe'; // Prefix to make valid
    }
    return safe;
  }

  static const _dartKeywords = {
    'abstract', 'else', 'import', 'show', 'as', 'enum', 'in', 'static', 'assert', 'export', 'interface', 'super', 'async', 'extends', 'is', 'switch', 'await', 'extension', 'library', 'sync', 'break', 'external', 'mixin', 'this', 'case', 'factory', 'new', 'throw', 'catch', 'false', 'null', 'true', 'class', 'final', 'on', 'try', 'const', 'finally', 'operator', 'typedef', 'continue', 'for', 'part', 'var', 'covariant', 'function', 'rethrow', 'void', 'default', 'get', 'return', 'while', 'deferred', 'hide', 'set', 'with', 'do', 'if', 'dynamic', 'implements', 'yield'
  };
}

class ShellExecutor {
  final Logger logger;
  ShellExecutor(this.logger);

  Future<void> execute(String executable, List<String> args, {String? workingDirectory, Map<String, String>? environment}) async {
    logger.debug('EXEC: $executable ${args.join(' ')}');
    final result = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: true,
    );

    // Buffers to capture output for error reporting
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();

    // Capture standard output
    result.stdout.transform(utf8.decoder).listen((data) {
      if (logger.verbose) stdout.write(data);
      stdoutBuffer.write(data);
    });

    // Capture error output
    result.stderr.transform(utf8.decoder).listen((data) {
      if (logger.verbose) stderr.write(data);
      stderrBuffer.write(data);
    });

    final code = await result.exitCode;
    if (code != 0) {
      // If we weren't verbose, the user hasn't seen the error yet. Print it now.
      if (!logger.verbose) {
        final errorOut = stderrBuffer.toString();
        final stdOut = stdoutBuffer.toString();

        logger.error('Command failed (Exit Code $code):');
        if (errorOut.trim().isNotEmpty) {
          logger.error(errorOut);
        } else if (stdOut.trim().isNotEmpty) {
          // Some tools output errors to stdout
          logger.error(stdOut);
        } else {
          logger.error('No output captured.');
        }
      }
      throw ToolException('Command "$executable" failed with exit code $code');
    }
  }
}

class Logger {
  final bool verbose;
  Logger({required this.verbose});

  void info(String msg) => stdout.writeln(msg);
  void success(String msg) => stdout.writeln('\x1b[32m$msg\x1b[0m');
  void error(String msg) => stderr.writeln('\x1b[31m$msg\x1b[0m');
  void debug(String msg) {
    if (verbose) stdout.writeln('\x1b[90m[DEBUG] $msg\x1b[0m');
  }
}

class ToolException implements Exception {
  final String message;
  ToolException(this.message);
  @override
  String toString() => message;
}