import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:code_builder/code_builder.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as path;
import 'package:recase/recase.dart';

import '../constants.dart';
import '../templates/fantasticon_config_template.dart';

/// =============================================================================
/// SvgToFont: Font Generator
/// =============================================================================
///
/// ARCHITECTURE:
/// 1. **Command Layer**: Handles CLI arguments.
/// 2. **Processing Layer**: Normalizes input files.
/// 3. **Generation Layer (Strategy Pattern)**:
///    - `FantasticonGenerator`: Node.js for mono icons.
///    - `NanoEmojiGenerator`: Python for color icons (COLRv0).
/// 4. **Output Layer**: Generates Dart code.
///
/// COMPATIBILITY NOTES:
/// - **Color Fonts**: Uses `COLRv0` (glyf_colr_0).
///   - iOS 12+ (CoreText) & Android 8.1+ support.
///   - **Constraint**: Requires Vector SVGs. Bitmaps (PNGs) are NOT supported in COLRv0.

// =============================================================================
// 1. Core Command (The Entry Point)
// =============================================================================

class SvgToFontCommand extends Command<int> {
  SvgToFontCommand() {
    argParser
      ..addOption(
        svgInputDir,
        abbr: 'i',
        help: 'Input path of SVG files',
        mandatory: true,
      )
      ..addOption(
        fontOutputDir,
        abbr: 'o',
        help: 'Output path for .ttf fonts',
        mandatory: true,
      )
      ..addOption(
        iconsOutputDir,
        abbr: 'c',
        help: 'Output path for Dart class',
        mandatory: true,
      )
      ..addOption(
        iconsClassName,
        abbr: 'n',
        defaultsTo: defaultIconsClassName,
        help: 'Class name for icons (e.g., MyIcons)',
      )
      ..addOption(
        iconsPackageName,
        abbr: 'p',
        help: 'Package name (if generating for a package/library)',
      )
      ..addFlag(
        allIconsMap,
        defaultsTo: true,
        help: 'Includes map of all icons to the generated dart class',
      )
      ..addFlag(
        deleteInput,
        defaultsTo: false,
        help: 'Delete input SVGs after generation',
      )
      ..addFlag(
        useColor,
        defaultsTo: false,
        help: 'Enable colored icon generation (Requires Python/Nanoemoji)',
      )
      ..addFlag(
        verbose,
        abbr: 'v',
        defaultsTo: false,
        help: 'Show detailed logs',
      )
      ..addFlag(
        keepTemp,
        defaultsTo: false,
        help: 'Keep temporary files for debugging',
      );
  }

  @override
  String get name => 'generate';

  @override
  String get description =>
      'Generates font files and Flutter Icon classes from SVGs.';

  @override
  Future<int> run() async {
    final bool isVerbose = argResults![verbose];
    final bool shouldKeepTemp = argResults![keepTemp];
    final Logger logger = Logger(verbose: isVerbose);
    final ShellExecutor shell = ShellExecutor(logger);

    Directory? workspaceDir;

    try {
      logger.info('🚀 Starting SvgToFont generation...');

      // 1. Setup Workspace (Use System Temp to avoid permission issues)
      workspaceDir = Directory.systemTemp.createTempSync('svg_to_font_build_');
      logger.debug('Workspace created at: ${workspaceDir.path}');

      // 2. Parse Inputs
      final Directory inputDir = Directory(argResults![svgInputDir]);
      final Directory fontOutDir = Directory(argResults![fontOutputDir]);
      final Directory iconsOutDir = Directory(argResults![iconsOutputDir]);
      final String className = argResults![iconsClassName];
      final String? packageName = argResults![iconsPackageName];
      final bool includeAll = argResults![allIconsMap];
      final bool isColor = argResults![useColor];

      if (!inputDir.existsSync()) {
        throw ToolException('Input directory does not exist: ${inputDir.path}');
      }

      // 3. Normalize SVGs
      final SvgProcessor processor = SvgProcessor(logger, workspaceDir);
      final SvgProcessingResult processingResult =
          await processor.prepareSvgs(inputDir);

      if (processingResult.files.isEmpty) {
        throw ToolException(
          'No supported files (SVG) found in ${inputDir.path}. Note: PNGs are not supported.',
        );
      }

      // 4. Select Strategy & Generate Font
      final FontGenerator generator = isColor
          ? NanoEmojiGenerator(shell, logger, workspaceDir)
          : FantasticonGenerator(shell, logger, workspaceDir);

      logger.info(
        '🛠  Checking prerequisites for ${isColor ? "Color" : "Mono"} mode...',
      );
      await generator.checkPrerequisites();

      logger.info('⚙️  Generating font...');
      final FontGenerationResult generationResult = await generator.generate(
        processingResult.files,
        className,
      );

      // Print Mapping Table for Debugging
      logger.info('\n📊 Icon Mapping Table (Verify these match Dart code):');
      generationResult.glyphMap.forEach((String name, int code) {
        logger.info('  $name -> 0x${code.toRadixString(16).toUpperCase()}');
      });
      logger.info('');

      // 5. Generate Flutter Code
      logger.info('📝 Generating Dart code...');
      final DartClassGenerator codeGenerator = DartClassGenerator();
      final String dartCode = codeGenerator.generate(
        className: className,
        packageName: packageName,
        glyphMap: generationResult.glyphMap,
        originalFileMap: processingResult.originalPathMap,
        includeAll: includeAll,
      );

      // 6. Delivery
      await _deliverArtifacts(
        fontFile: generationResult.fontFile,
        dartContent: dartCode,
        fontOutputDir: fontOutDir,
        iconsOutputDir: iconsOutDir,
        className: className,
        logger: logger,
      );

      // 7. Cleanup
      if (argResults![deleteInput]) {
        logger.info('🗑  Deleting source SVGs...');
        await inputDir.delete(recursive: true);
      }

      final String fontFileName = '${ReCase(className).snakeCase}.ttf';

      logger.success('✅ Generation complete!');

      // Critical Instruction for Flutter Developers
      logger.info(
        '⚠️  CRITICAL: You MUST run the following commands to clear the font cache:',
      );
      logger.info('   flutter clean');
      logger.info('   flutter pub get');
      logger.info(
        '   (Then uninstall the app from the simulator/device before running again)',
      );

      logger.info('\n📝 pubspec.yaml entry:');
      logger.info('''
  fonts:
    - family: $className
      fonts:
        - asset: ${path.join(argResults![fontOutputDir], fontFileName)}
''');
      return 0;
    } on ToolException catch (e) {
      logger.error(e.message);
      return 1;
    } catch (e, stack) {
      logger.error('Unexpected error: $e');
      if (isVerbose) {
        logger.error(stack.toString());
      }
      return 1;
    } finally {
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
    if (!fontOutputDir.existsSync()) {
      await fontOutputDir.create(recursive: true);
    }
    if (!iconsOutputDir.existsSync()) {
      await iconsOutputDir.create(recursive: true);
    }

    final String fontFileName = '${ReCase(className).snakeCase}.ttf';
    final String targetFontPath = path.join(fontOutputDir.path, fontFileName);

    // Sanity check
    if (await fontFile.length() < 100) {
      throw ToolException(
        'Generated font file is suspiciously small or empty. Generation likely failed.',
      );
    }

    await fontFile.copy(targetFontPath);
    logger.info('Checking out font: $targetFontPath');

    final String targetDartPath =
        path.join(iconsOutputDir.path, '${ReCase(className).snakeCase}.dart');
    await File(targetDartPath).writeAsString(dartContent);
    logger.info('Checking out code: $targetDartPath');
  }
}

// =============================================================================
// 2. Domain Logic: Font Generators (Strategy Pattern)
// =============================================================================

class FontGenerationResult {
  FontGenerationResult(this.fontFile, this.glyphMap);

  final File fontFile;
  final Map<String, int> glyphMap;
}

abstract class FontGenerator {
  FontGenerator(this.shell, this.logger, this.workspace);

  final ShellExecutor shell;
  final Logger logger;
  final Directory workspace;

  Future<void> checkPrerequisites();

  Future<FontGenerationResult> generate(List<File> files, String className);
}

/// ----------------------------------------------------------------------------
/// Strategy A: Monotone Fonts (Node.js + Fantasticon)
/// ----------------------------------------------------------------------------
class FantasticonGenerator extends FontGenerator {
  FantasticonGenerator(super.shell, super.logger, super.workspace);

  @override
  Future<void> checkPrerequisites() async {
    try {
      await shell.execute('node', <String>['--version']);
      await shell.execute('npm', <String>['--version']);
    } catch (e) {
      throw ToolException('NodeJS and NPM are required. Please install them.');
    }
  }

  @override
  Future<FontGenerationResult> generate(
    List<File> files,
    String className,
  ) async {
    if (files.isEmpty) {
      throw ToolException('No files provided for mono generation.');
    }

    final File packageJson = File(path.join(workspace.path, 'package.json'));
    await packageJson
        .writeAsString('{"name": "temp_font_gen", "private": true}');

    logger.info('Installing fantasticon in temporary workspace...');
    await shell.execute(
      'npm',
      <String>['install', 'fantasticon'],
      workingDirectory: workspace.path,
    );

    final Directory inputDir = Directory(path.join(workspace.path, 'icons'));
    if (!inputDir.existsSync()) {
      inputDir.createSync();
    }

    for (final File f in files) {
      await f.copy(path.join(inputDir.path, path.basename(f.path)));
    }

    final Directory outputDir = Directory(path.join(workspace.path, 'out'));
    if (!outputDir.existsSync()) {
      outputDir.createSync();
    }

    final String fontName = ReCase(className).snakeCase;

    final File configFile =
        File(path.join(workspace.path, 'fantasticonrc.json'));
    if (!configFile.existsSync()) {
      try {
        await configFile.writeAsString(fantasticonConfigTemplate);
      } catch (_) {
        await configFile.writeAsString('{}');
      }
    }

    await configFile.writeAsString(
      jsonEncode(<String, Object>{
        'name': fontName,
        'outputDir': outputDir.path,
        'inputDir': inputDir.path,
        'fontTypes': <String>['ttf'],
        'assetTypes': <String>['json'],
        'formatOptions': <String, Map<String, int>>{
          'json': <String, int>{'indent': 2},
        },
      }),
    );

    await shell.execute(
      path.join(workspace.path, 'node_modules', '.bin', 'fantasticon'),
      <String>['-c', configFile.path],
      workingDirectory: workspace.path,
    );

    final File ttf = File(path.join(outputDir.path, '$fontName.ttf'));
    final File mapFile = File(path.join(outputDir.path, '$fontName.json'));

    if (!ttf.existsSync() || !mapFile.existsSync()) {
      throw ToolException('Fantasticon failed to produce output files.');
    }

    final Map<String, dynamic> rawMap =
        jsonDecode(await mapFile.readAsString());
    final Map<String, int> glyphMap = rawMap.map((String key, dynamic value) =>
        MapEntry<String, int>(key, value as int));

    return FontGenerationResult(ttf, glyphMap);
  }
}

/// ----------------------------------------------------------------------------
/// Strategy B: Color Fonts (Python + NanoEmoji)
/// ----------------------------------------------------------------------------
/// Uses `nanoemoji` to create COLRv0 fonts.
/// COLRv0 is chosen for native stability on iOS 12+ and Android 8+.
class NanoEmojiGenerator extends FontGenerator {
  NanoEmojiGenerator(super.shell, super.logger, super.workspace);

  @override
  Future<void> checkPrerequisites() async {
    try {
      await shell.execute('python3', <String>['--version']);
    } catch (e) {
      throw ToolException('Python 3 is required for color fonts.');
    }
  }

  @override
  Future<FontGenerationResult> generate(
    List<File> files,
    String className,
  ) async {
    final String venvPath = path.join(workspace.path, 'venv');
    logger.info('Creating Python virtual environment...');
    await shell.execute('python3', <String>['-m', 'venv', venvPath]);

    final String pipPath = path.join(venvPath, 'bin', 'pip');
    final String nanoPath = path.join(venvPath, 'bin', 'nanoemoji');

    logger.info('Installing nanoemoji (this may take a moment)...');
    await shell.execute(
      pipPath,
      <String>['install', 'nanoemoji', 'ninja'],
      workingDirectory: workspace.path,
    );

    // Prepare Files with PUA Codepoints
    // We strictly rename files to `uE000.svg` to prevent system emoji conflicts.
    final Directory preparedDir =
        Directory(path.join(workspace.path, 'prepared_icons'));
    preparedDir.createSync();

    final Map<String, int> glyphMap = <String, int>{};
    int currentCodePoint = 0xE000;
    final List<String> fileArgs = <String>[];

    // Sort to ensure deterministic assignment order
    files.sort(
      (File a, File b) =>
          path.basename(a.path).compareTo(path.basename(b.path)),
    );

    for (File file in files) {
      final String name = path.basenameWithoutExtension(file.path);
      final String ext = path.extension(file.path).toLowerCase();

      final String hexCode = currentCodePoint.toRadixString(16).toUpperCase();
      final String newName = 'u$hexCode$ext';
      final String newPath = path.join(preparedDir.path, newName);

      await file.copy(newPath);

      glyphMap[name] = currentCodePoint;
      fileArgs.add(newPath);
      currentCodePoint++;
    }

    final String fontName = ReCase(className).snakeCase;
    final String outputFile = path.join(workspace.path, '$fontName.ttf');

    // Add venv/bin to PATH so ninja (build system) is found
    final String venvBin = path.join(venvPath, 'bin');
    final Map<String, String> env = <String, String>{
      'PATH': '$venvBin:${Platform.environment['PATH'] ?? ''}',
    };

    logger.info('Running nanoemoji (Setting family to "$className")...');

    // EXECUTION FLAGS:
    // --color_format glyf_colr_0: Forces COLRv0 (Vector). Max compatibility.
    // --family: Sets the internal font family name to match Flutter's pubspec.
    // --upem/ascender/descender: Standardizes metrics.
    await shell.execute(
      nanoPath,
      <String>[
        '--color_format',
        'glyf_colr_0',
        '--family',
        className,
        '--upem',
        '1000',
        '--ascender',
        '1000',
        '--descender',
        '0',
        '--width',
        '1000',
        '--output_file',
        outputFile,
        ...fileArgs,
      ],
      environment: env,
      workingDirectory: workspace.path,
    );

    final File ttf = File(outputFile);
    if (!ttf.existsSync()) {
      throw ToolException('Nanoemoji failed to generate TTF.');
    }

    return FontGenerationResult(ttf, glyphMap);
  }
}

// =============================================================================
// 3. Utilities: Processing, Generation, & Execution
// =============================================================================

class SvgProcessingResult {
  SvgProcessingResult(this.files, this.originalPathMap);

  final List<File> files;
  final Map<String, String> originalPathMap;
}

class SvgProcessor {
  SvgProcessor(this.logger, this.workspace);

  final Logger logger;
  final Directory workspace;

  Future<SvgProcessingResult> prepareSvgs(Directory inputDir) async {
    final List<File> validFiles = <File>[];
    final Map<String, String> originalPaths = <String, String>{};
    final Directory processingDir =
        Directory(path.join(workspace.path, 'raw_icons'));
    processingDir.createSync();

    await for (final FileSystemEntity entity
        in inputDir.list(recursive: true)) {
      if (entity is File) {
        final String ext = path.extension(entity.path).toLowerCase();

        // STRICT FILTERING: COLRv0 is vector-only.
        if (ext == '.svg') {
          final String baseName = path.basenameWithoutExtension(entity.path);
          final String safeName = ReCase(baseName).snakeCase;

          final File dest =
              File(path.join(processingDir.path, '$safeName$ext'));
          await entity.copy(dest.path);

          validFiles.add(dest);
          originalPaths[safeName] = entity.path;
        } else if (ext == '.png') {
          logger.info(
            '⚠️  Skipping ${path.basename(entity.path)}: PNGs are not supported for high-compatibility Color Fonts (COLRv0). Please convert to SVG.',
          );
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
    required bool includeAll,
  }) {
    final Library library = Library(
      (LibraryBuilder b) => b
        ..comments.addAll(<String>[
          'coverage:ignore-file',
          '*****************************************************',
          'GENERATED CODE - DO NOT MODIFY BY HAND',
          '*****************************************************',
        ])
        ..generatedByComment = 'kamona_svg_to_font'
        ..ignoreForFile.addAll(<String>[
          'sort_constructors_first',
          'public_member_api_docs',
          'constant_identifier_names',
        ])
        ..name = ''
        ..directives.add(Directive.import('package:flutter/widgets.dart'))
        ..body.add(
          Class(
            (ClassBuilder c) {
              c
                ..name = className
                ..abstract = true
                ..constructors
                    .add(Constructor((ConstructorBuilder c) => c..name = '_'))
                ..fields.add(
                  Field(
                    (FieldBuilder f) => f
                      ..name = 'fontFamily'
                      ..static = true
                      ..modifier = FieldModifier.constant
                      ..type = refer('String')
                      ..assignment = literalString(className).code,
                  ),
                )
                ..fields.add(
                  Field(
                    (FieldBuilder f) => f
                      ..name = 'fontPackage'
                      ..static = true
                      ..modifier = FieldModifier.constant
                      ..type = refer(packageName != null ? 'String' : 'String?')
                      ..assignment = packageName != null
                          ? literalString(packageName).code
                          : literalNull.code,
                  ),
                )
                ..fields.addAll(_buildIconFields(glyphMap, originalFileMap));
              if (includeAll) {
                c.fields.add(_buildAllField(glyphMap));
              }
            },
          ),
        ),
    );

    final DartEmitter emitter = DartEmitter(
      allocator: Allocator.simplePrefixing(),
      orderDirectives: true,
      useNullSafetySyntax: true,
    );

    return DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
        .format('${library.accept(emitter)}');
  }

  Iterable<Field> _buildIconFields(
    Map<String, int> glyphs,
    Map<String, String> originalPaths,
  ) {
    return glyphs.entries.map((MapEntry<String, int> e) {
      final String sanitizedName = _sanitizeIdentifier(e.key);
      final String originalPath = originalPaths[e.key] ?? 'unknown';

      return Field(
        (FieldBuilder f) => f
          ..name = sanitizedName
          ..static = true
          ..modifier = FieldModifier.constant
          ..type = refer('IconData')
          ..docs.add('/// File: $originalPath')
          ..assignment = refer('IconData').call(<Expression>[
            // Use Hex format (0xE001) for readability
            CodeExpression(Code('0x${e.value.toRadixString(16)}')),
          ], <String, Expression>{
            'fontFamily': refer('fontFamily'),
            'fontPackage': refer('fontPackage'),
          }).code,
      );
    });
  }

  Field _buildAllField(Map<String, int> glyphs) {
    final Map<Object, Object> mapContent = <Object, Object>{};
    for (final String key in glyphs.keys) {
      final String sanitized = _sanitizeIdentifier(key);
      // Use the ORIGINAL glyph name as the map key (string), and the sanitized
      // identifier as the value reference. This prevents reserved words from
      // appearing as unquoted identifiers in generated code.
      mapContent[key] = refer(sanitized);
    }

    return Field(
      (FieldBuilder f) => f
        ..name = 'all'
        ..static = true
        ..modifier = FieldModifier.constant
        ..type = refer('Map<String, IconData>')
        ..assignment =
            literalMap(mapContent, refer('String'), refer('IconData')).code,
    );
  }

  String _sanitizeIdentifier(String name) {
    // Convert to snake_case first
    String safe = ReCase(name).snakeCase;

    // Remove any characters not allowed in Dart identifiers (keep a-z, 0-9, and _)
    safe = safe.replaceAll(RegExp(r'[^a-z0-9_]+'), '');

    // If empty after cleaning, give a default base name
    if (safe.isEmpty) {
      safe = 'icon';
    }

    // Ensure it starts with a letter or underscore; if not, prefix to make valid
    if (!RegExp(r'^[a-zA-Z_]').hasMatch(safe)) {
      safe = 'icon_$safe';
    }

    // If it starts with a digit (edge-case after replacements), prefix as well
    if (RegExp(r'^[0-9]').hasMatch(safe)) {
      safe = 'icon_$safe';
    }

    // If the sanitized name is a Dart keyword, suffix with `_icon` instead of prefixing.
    if (_dartKeywords.contains(safe)) {
      safe = '${safe}_icon';
    }

    return safe;
  }

  static const Set<String> _dartKeywords = <String>{
    'abstract',
    'else',
    'import',
    'show',
    'as',
    'enum',
    'in',
    'static',
    'assert',
    'export',
    'interface',
    'super',
    'async',
    'extends',
    'is',
    'switch',
    'await',
    'extension',
    'library',
    'sync',
    'break',
    'external',
    'mixin',
    'this',
    'case',
    'factory',
    'new',
    'throw',
    'catch',
    'false',
    'null',
    'true',
    'class',
    'final',
    'on',
    'try',
    'const',
    'finally',
    'operator',
    'typedef',
    'continue',
    'for',
    'part',
    'var',
    'covariant',
    'function',
    'rethrow',
    'void',
    'default',
    'get',
    'return',
    'while',
    'deferred',
    'hide',
    'set',
    'with',
    'do',
    'if',
    'dynamic',
    'implements',
    'yield',
  };
}

class ShellExecutor {
  ShellExecutor(this.logger);

  final Logger logger;

  Future<void> execute(
    String executable,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    logger.debug('EXEC: $executable ${args.join(' ')}');
    final Process result = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      runInShell: true,
    );

    final StringBuffer stdoutBuffer = StringBuffer();
    final StringBuffer stderrBuffer = StringBuffer();

    result.stdout.transform(utf8.decoder).listen((String data) {
      if (logger.verbose) {
        stdout.write(data);
      }
      stdoutBuffer.write(data);
    });

    result.stderr.transform(utf8.decoder).listen((String data) {
      if (logger.verbose) {
        stderr.write(data);
      }
      stderrBuffer.write(data);
    });

    final int code = await result.exitCode;
    if (code != 0) {
      if (!logger.verbose) {
        final String errorOut = stderrBuffer.toString();
        final String stdOut = stdoutBuffer.toString();

        logger.error('Command failed (Exit Code $code):');
        if (errorOut.trim().isNotEmpty) {
          logger.error(errorOut);
        } else if (stdOut.trim().isNotEmpty) {
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
  Logger({required this.verbose});

  final bool verbose;

  void info(String msg) => stdout.writeln(msg);

  void success(String msg) => stdout.writeln('\x1b[32m$msg\x1b[0m');

  void error(String msg) => stderr.writeln('\x1b[31m$msg\x1b[0m');

  void debug(String msg) {
    if (verbose) {
      stdout.writeln('\x1b[90m[DEBUG] $msg\x1b[0m');
    }
  }
}

class ToolException implements Exception {
  ToolException(this.message);

  final String message;

  @override
  String toString() => message;
}
