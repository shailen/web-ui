// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library compiler;

import 'dart:coreimpl';
import 'package:html5lib/dom.dart';
import 'package:html5lib/parser.dart';

import 'analyzer.dart';
import 'code_printer.dart';
import 'codegen.dart' as codegen;
import 'emitters.dart';
import 'file_system.dart';
import 'files.dart';
import 'info.dart';
import 'utils.dart';
import 'world.dart';

// TODO(jmesserly): move these things into html5lib's public api
// This is for voidElements:
import 'package:html5lib/src/constants.dart' as html5_constants;
// This is for htmlEscapeMinimal:
import 'package:html5lib/src/utils.dart' as html5_utils;


Document parseHtml(String template, String sourcePath) {
  var parser = new HtmlParser(template, generateSpans: true);
  var document = parser.parse();

  // Note: errors aren't fatal in HTML (unless strict mode is on).
  // So just print them as warnings.
  for (var e in parser.errors) {
    world.warning('line ${e.line}:${e.column}: ${e.message}', filename:
        sourcePath );
  }
  return document;
}

/**
 * Walk the tree produced by the parser looking for templates, expressions, etc.
 * as a prelude to emitting the code for the template.
 */
class Compiler {
  final FileSystem filesystem;
  final List<SourceFile> files = <SourceFile>[];
  final List<OutputFile> output = <OutputFile>[];

  /** Information about source [files] given their href. */
  final Map<String, FileInfo> info = new SplayTreeMap<String, FileInfo>();

  /** Used by template tool to open a file. */
  Compiler(this.filesystem);

  /** Compile the application starting from the given [mainFile]. */
  Future run(String mainFile, [String baseDir = ""]) {
    return _parseAndDiscover(mainFile, baseDir).transform((_) {
      _analyze();
      _emit();
      return null;
    });
  }

  /**
   * Asynchronously parse [inputFile] and recursively discover web components to
   * load and parse.  Returns a future that completes when all files are
   * processed.
   */
  Future _parseAndDiscover(String inputFile, String baseDir) {
    var pending = new Queue<String>(); // files to process

    Completer done = new Completer();
    // We are not done until the number of in progress requests goes back to 0.
    int inProgress = 0;

    notifyIfDone() {
      assert(inProgress >= 0);
      if (inProgress == 0) {
        done.complete(null);
      }
    }

    pending.addLast(inputFile);

    parsePending() {
      while (!pending.isEmpty()) {
        var filename = pending.removeFirst();

        // Parse the file.
        if (info.containsKey(filename)) continue;

        inProgress++;

        _parseHtmlFile(filename, baseDir).then((file) {
          files.add(file);

          // Find additional components being loaded.
          var fileInfo = time('Analyzed definitions ${file.filename}',
              () => analyzeDefinitions(
                  file, isEntryPoint: filename == inputFile));
          info[file.filename] = fileInfo;
          for (var href in fileInfo.componentLinks) {
            pending.addLast(href);
          }
          // Load .dart files being referenced in the page and components.
          if (fileInfo.externalFile != null) {
            inProgress++;
            _parseDartFile(fileInfo.externalFile, baseDir).then((dartFile) {
              _addDartFile(dartFile);
              inProgress--;
              notifyIfDone();
            });
          }

          for (var component in fileInfo.declaredComponents) {
            var src = component.externalFile;
            if (src != null) {
              inProgress++;
              _parseDartFile(src, baseDir).then((dartFile) {
                _addDartFile(dartFile);
                inProgress--;
                notifyIfDone();
              });
            }
          }
          inProgress--;
          parsePending();
        });
      }
      notifyIfDone();
    }

    parsePending();
    return done.future;
  }

  /** Asynchronously parse [filename]. */
  Future<SourceFile> _parseHtmlFile(String filename, String baseDir) {
    return filesystem.readAll("$baseDir/$filename").transform((source) {
      var file = new SourceFile(filename);
      file.document = time("Parsed $filename",
          () => parseHtml(source, filename));
      if (options.dumpTree) {
        print("\n\n Dump Tree $filename:\n\n");
        print(file.document.outerHTML);
        print("\n=========== End of AST ===========\n\n");
      }
      return file;
    });
  }

  /** Parse [filename] and treat it as a .dart file. */
  Future<SourceFile> _parseDartFile(String filename, String baseDir) {
    return filesystem.readAll("$baseDir/$filename").transform((source) =>
      new SourceFile(filename, isDart: true)
        ..code = source);
  }

  Future _addDartFile(SourceFile dartFile) {
    var fileInfo = new FileInfo(dartFile.filename);
    info[dartFile.filename] = fileInfo;
    fileInfo.inlinedCode = dartFile.code;
    files.add(dartFile);
  }

  /** Run the analyzer on every input html file. */
  void _analyze() {
    for (var file in files) {
      if (file.isDart) continue;
      time('Analyzed contents ${file.filename}', () => analyzeFile(file, info));
    }
  }

  /** Emit the generated code corresponding to each input file. */
  void _emit() {
    for (var file in files) {
      time('Codegen ${file.filename}', () {
        if (!file.isDart) {
          _removeScriptTags(file.document);
          _fixImports(file);
          _emitComponents(file);

          var fileInfo = info[file.filename];
          if (fileInfo.isEntryPoint && fileInfo.codeAttached) {
            _emitMainDart(file);
            _emitMainHtml(file);
          } else {
            _emitComponentDart(file);
            _emitComponentHtml(file);
          }
        }
      });
    }
  }

  static const String DARTJS_LOADER =
    "http://dart.googlecode.com/svn/branches/bleeding_edge/dart/client/dart.js";

  /** Adds imports to [file] for each used component. */
  // TODO(sigmund): delete - this inlining of imports is added here just
  // because we currently have no way to re-export libraries (issue #58).
  void _fixImports(SourceFile file) {
    var fileInfo = info[file.filename];
    for (var component in fileInfo.components.getValues()) {
      fileInfo.imports[component.outputFilename] = true;
    }
  }

  /** Emit the main .dart file. */
  void _emitMainDart(SourceFile file) {
    var fileInfo = info[file.filename];
    output.add(new OutputFile(fileInfo.outputFilename,
        new MainPageEmitter(fileInfo).run(file.document)));
  }

  /** Generate an html file with the (trimmed down) main html page. */
  void _emitMainHtml(SourceFile file) {
    var fileInfo = info[file.filename];

    // Clear the body, we moved all of it
    var document = file.document;
    document.body.nodes.clear();
    output.add(new OutputFile('_${file.filename}_bootstrap.dart',
          codegen.bootstrapCode(fileInfo.outputFilename)));
    document.body.nodes.add(parseFragment(
      '<script type="text/javascript" src="$DARTJS_LOADER"></script>'
      '<script type="application/dart" src="_${file.filename}_bootstrap.dart">'
      '</script>'
    ));

    for (var link in document.head.queryAll('link')) {
      if (link.attributes["rel"] == "components") {
        link.remove();
      }
    }

    _addAutoGeneratedComment(file);
    output.add(new OutputFile('_${file.filename}.html', document.outerHTML));
  }

  /** Emits the Dart code for all components in the [file]. */
  void _emitComponents(SourceFile file) {
    var fileInfo = info[file.filename];
    for (var component in fileInfo.declaredComponents) {
      var code = new WebComponentEmitter(fileInfo).run(component);
      output.add(new OutputFile(component.outputFilename, code));
    }
  }

  /** Emit the wrapper .dart file for a component page. */
  void _emitComponentDart(SourceFile file) {
    var fileInfo = info[file.filename];
    output.add(new OutputFile(fileInfo.outputFilename, new CodePrinter().add('''
        // Auto-generated from ${file.filename}.
        // DO NOT EDIT.

        library ${fileInfo.libraryName};

        ${codegen.exportList(fileInfo.imports.getKeys())}
        ''').formatString()));
  }

  /** Generate an html file declaring a web component. */
  void _emitComponentHtml(SourceFile file) {
    _addAutoGeneratedComment(file);
    output.add(new OutputFile(
        '_${file.filename}.html', file.document.outerHTML));
  }


  void _removeScriptTags(Document doc) {
    for (var tag in doc.queryAll('script')) {
      if (tag.attributes['type'] == 'application/dart') {
        tag.remove();
      }
    }
  }
}

void _addAutoGeneratedComment(SourceFile file) {
  var document = file.document;

  // Insert the "auto-generated" comment after the doctype, otherwise IE will go
  // into quirks mode.
  int commentIndex = 0;
  DocumentType doctype = find(document.nodes, (n) => n is DocumentType);
  if (doctype != null) {
    commentIndex = document.nodes.indexOf(doctype) + 1;
    // TODO(jmesserly): the html5lib parser emits a warning for missing doctype,
    // but it allows you to put it after comments. Presumably they do this
    // because some comments won't force IE into quirks mode (sigh). See this
    // link for more info:
    //     http://bugzilla.validator.nu/show_bug.cgi?id=836
    // For simplicity we're emitting the warning always, like validator.nu does.
    if (doctype.tagName != 'html' || commentIndex != 1) {
      world.warning('file should start with <!DOCTYPE html> '
          'to avoid the possibility of it being parsed in quirks mode in IE. '
          'See http://www.w3.org/TR/html5-diff/#doctype', filename:
          file.filename);
    }
  }
  document.nodes.insertAt(commentIndex, parseFragment(
      '\n<!-- This file was auto-generated from template '
              '${file.filename}. -->\n'));
}