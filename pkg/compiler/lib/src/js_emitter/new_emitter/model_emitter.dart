// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart2js.new_js_emitter.model_emitter;

import '../../dart2jslib.dart' show Compiler;
import '../../js/js.dart' as js;
import '../../js_backend/js_backend.dart' show
    JavaScriptBackend,
    Namer,
    ConstantEmitter;

import 'package:_internal/compiler/js_lib/shared/embedded_names.dart' show
    DEFERRED_LIBRARY_URIS,
    DEFERRED_LIBRARY_HASHES,
    INITIALIZE_LOADED_HUNK,
    IS_HUNK_INITIALIZED,
    IS_HUNK_LOADED;

import '../js_emitter.dart' show NativeGenerator;
import '../model.dart';

class ModelEmitter {
  final Compiler compiler;
  final Namer namer;
  final ConstantEmitter constantEmitter;

  JavaScriptBackend get backend => compiler.backend;

  /// For deferred loading we communicate the initializers via this global var.
  static const String deferredInitializersGlobal =
      r"$__dart_deferred_initializers__";

  static const String deferredExtension = "part.js";

  ModelEmitter(Compiler compiler, Namer namer)
      : this.compiler = compiler,
        this.namer = namer,
        constantEmitter =
            new ConstantEmitter(compiler, namer, makeConstantListTemplate);

  js.Expression generateEmbeddedGlobalAccess(String global) {
    // TODO(floitsch): We should not use "init" for globals.
    return js.js("init.$global");
  }

  int emitProgram(Program program) {
    List<Fragment> fragments = program.fragments;
    MainFragment mainFragment = fragments.first;
    js.Statement mainAst = emitMainFragment(program);
    String mainCode = js.prettyPrint(mainAst, compiler).getText();
    compiler.outputProvider(mainFragment.outputFileName, 'js')
        ..add(buildGeneratedBy(compiler))
        ..add(mainCode)
        ..close();
    int totalSize = mainCode.length;

    fragments.skip(1).forEach((DeferredFragment deferredUnit) {
      js.Expression ast =
          emitDeferredFragment(deferredUnit, mainFragment.holders);
      String code = js.prettyPrint(ast, compiler).getText();
      totalSize += code.length;
      compiler.outputProvider(deferredUnit.outputFileName, deferredExtension)
          ..add(code)
          ..close();
    });
    return totalSize;
  }

  js.LiteralString unparse(Compiler compiler, js.Expression value) {
    String text = js.prettyPrint(value, compiler).getText();
    if (value is js.Fun) text = '($text)';
    return js.js.escapedString(text);
  }

  String buildGeneratedBy(compiler) {
    var suffix = '';
    if (compiler.hasBuildId) suffix = ' version: ${compiler.buildId}';
    return '// Generated by dart2js, the Dart to JavaScript compiler$suffix.\n';
  }

  js.Statement emitMainFragment(Program program) {
    MainFragment fragment = program.fragments.first;
    List<js.Expression> elements = fragment.libraries.map(emitLibrary).toList();
    elements.add(
        emitLazilyInitializedStatics(fragment.staticLazilyInitializedFields));

    js.Statement nativeBoilerplate;
    if (NativeGenerator.needsIsolateAffinityTagInitialization(backend)) {
      nativeBoilerplate =
          NativeGenerator.generateIsolateAffinityTagInitialization(
              backend,
              generateEmbeddedGlobalAccess,
              // TODO(floitsch): convertToFastObject.
              js.js("(function(x) { return x; })", []));
    } else {
      nativeBoilerplate = js.js.statement(";");
    }

    js.Expression code = new js.ArrayInitializer(elements);

    return js.js.statement(
        boilerplate,
        {'deferredInitializer': emitDeferredInitializerGlobal(program.loadMap),
         'holders': emitHolders(fragment.holders),
         'cyclicThrow':
           backend.emitter.staticFunctionAccess(backend.getCyclicThrowHelper()),
         'outputContainsConstantList': program.outputContainsConstantList,
         'embeddedGlobals': emitEmbeddedGlobals(program.loadMap),
         'constants': emitConstants(fragment.constants),
         'staticNonFinals': emitStaticNonFinalFields(fragment.staticNonFinalFields),
         'nativeBoilerplate': nativeBoilerplate,
         'eagerClasses': emitEagerClassInitializations(fragment.libraries),
         'main': fragment.main,
         'code': code});
  }

  js.Block emitHolders(List<Holder> holders) {
    // The top-level variables for holders must *not* be renamed by the
    // JavaScript pretty printer because a lot of code already uses the
    // non-renamed names. The generated code looks like this:
    //
    //    var H = {}, ..., G = {};
    //    var holders = [ H, ..., G ];
    //
    // and it is inserted at the top of the top-level function expression
    // that covers the entire program.

    List<js.Statement> statements = [
        new js.ExpressionStatement(
            new js.VariableDeclarationList(holders.map((e) =>
                new js.VariableInitialization(
                    new js.VariableDeclaration(e.name, allowRename: false),
                    new js.ObjectInitializer(const []))).toList())),
        js.js.statement('var holders = #', new js.ArrayInitializer(
            holders.map((e) => new js.VariableUse(e.name))
                   .toList(growable: false)))
    ];
    return new js.Block(statements);
  }

  static js.Template get makeConstantListTemplate {
    // TODO(floitsch): remove hard-coded name.
    // TODO(floitsch): there is no harm in caching the template.
    return js.js.uncachedExpressionTemplate('makeConstList(#)');
  }

  js.Block emitEmbeddedGlobals(Map<String, List<Fragment>> loadMap) {
    List<js.Property> globals = <js.Property>[];

    if (loadMap.isNotEmpty) {
      globals.addAll(emitLoadUrisAndHashes(loadMap));
      globals.add(emitIsHunkLoadedFunction());
      globals.add(emitInitializeLoadedHunk());
    }

    js.ObjectInitializer globalsObject = new js.ObjectInitializer(globals);

    List<js.Statement> statements =
        [new js.ExpressionStatement(
            new js.VariableDeclarationList(
                [new js.VariableInitialization(
                    new js.VariableDeclaration("init", allowRename: false),
                    globalsObject)]))];
    return new js.Block(statements);
  }

  List<js.Property> emitLoadUrisAndHashes(Map<String, List<Fragment>> loadMap) {
    js.ArrayInitializer outputUris(List<Fragment> fragments) {
      return js.stringArray(fragments.map((DeferredFragment fragment) =>
          "${fragment.outputFileName}$deferredExtension"));
    }
    js.ArrayInitializer outputHashes(List<Fragment> fragments) {
      // TODO(floitsch): the hash must depend on the generated code.
      return js.numArray(
          fragments.map((DeferredFragment fragment) => fragment.hashCode));
    }

    List<js.Property> uris = new List<js.Property>(loadMap.length);
    List<js.Property> hashes = new List<js.Property>(loadMap.length);
    int count = 0;
    loadMap.forEach((String loadId, List<Fragment> fragmentList) {
      uris[count] =
          new js.Property(js.string(loadId), outputUris(fragmentList));
      hashes[count] =
          new js.Property(js.string(loadId), outputHashes(fragmentList));
      count++;
    });

    return <js.Property>[
         new js.Property(js.string(DEFERRED_LIBRARY_URIS),
                         new js.ObjectInitializer(uris)),
         new js.Property(js.string(DEFERRED_LIBRARY_HASHES),
                         new js.ObjectInitializer(hashes))
         ];
  }

  js.Statement emitDeferredInitializerGlobal(Map loadMap) {
    if (loadMap.isEmpty) return new js.Block.empty();

    return js.js.statement("""
  if (typeof($deferredInitializersGlobal) === 'undefined')
    var $deferredInitializersGlobal = Object.create(null);""");
  }

  js.Property emitIsHunkLoadedFunction() {
    js.Expression function =
        js.js("function(hash) { return !!$deferredInitializersGlobal[hash]; }");
    return new js.Property(js.string(IS_HUNK_LOADED), function);
  }

  js.Property emitInitializeLoadedHunk() {
    js.Expression function =
        js.js("function(hash) { eval($deferredInitializersGlobal[hash]); }");
    return new js.Property(js.string(INITIALIZE_LOADED_HUNK), function);
  }

  js.Expression emitDeferredFragment(DeferredFragment fragment,
                                     List<Holder> holders) {
    // TODO(floitsch): initialize eager classes.
    // TODO(floitsch): the hash must depend on the output.
    int hash = this.hashCode;
    if (fragment.constants.isNotEmpty) {
      throw new UnimplementedError("constants in deferred units");
    }
    js.ArrayInitializer content =
        new js.ArrayInitializer(fragment.libraries.map(emitLibrary)
                                                  .toList(growable: false));
    return js.js("$deferredInitializersGlobal[$hash] = #", content);
  }

  js.Block emitConstants(List<Constant> constants) {
    Iterable<js.Statement> statements = constants.map((Constant constant) {
      js.Expression code =
          constantEmitter.initializationExpression(constant.value);
      return js.js.statement("#.# = #;",
                             [constant.holder.name, constant.name, code]);
    });
    return new js.Block(statements.toList());
  }

  js.Block emitStaticNonFinalFields(List<StaticField> fields) {
    Iterable<js.Statement> statements = fields.map((StaticField field) {
      return js.js.statement("#.# = #;",
                             [field.holder.name, field.name, field.code]);
    });
    return new js.Block(statements.toList());
  }

  js.Expression emitLazilyInitializedStatics(List<StaticField> fields) {
    Iterable fieldDescriptors = fields.expand((field) =>
        [ js.string(field.name),
          js.string("${namer.getterPrefix}${field.name}"),
          js.number(field.holder.index),
          emitLazyInitializer(field) ]);
    return new js.ArrayInitializer(fieldDescriptors.toList(growable: false));
  }

  js.Block emitEagerClassInitializations(List<Library> libraries) {
    js.Statement createInstantiation(Class cls) {
      return js.js.statement('new #.#()', [cls.holder.name, cls.name]);
    }

    List<js.Statement> instantiations =
        libraries.expand((Library library) => library.classes)
                 .where((Class cls) => cls.isEager)
                 .map(createInstantiation)
                 .toList(growable: false);
    return new js.Block(instantiations);
  }

  js.Expression emitLibrary(Library library) {
    Iterable staticDescriptors = library.statics.expand((e) =>
        [ js.string(e.name), js.number(e.holder.index), emitStaticMethod(e) ]);
    Iterable classDescriptors = library.classes.expand((e) =>
        [ js.string(e.name), js.number(e.holder.index), emitClass(e) ]);

    js.Expression staticArray =
        new js.ArrayInitializer(staticDescriptors.toList(growable: false));
    js.Expression classArray =
        new js.ArrayInitializer(classDescriptors.toList(growable: false));

    return new js.ArrayInitializer([staticArray, classArray]);
  }

  js.Expression _generateConstructor(Class cls) {
    List<String> fieldNames = <String>[];

    // If the class is not directly instantiated we only need it for inheritance
    // or RTI. In either case we don't need its fields.
    if (cls.isDirectlyInstantiated && !cls.isNative) {
      fieldNames = cls.fields.map((Field field) => field.name).toList();
    }
    String name = cls.name;
    String parameters = fieldNames.join(', ');
    String assignments = fieldNames
        .map((String field) => "this.$field = $field;\n")
        .join();
    String code = 'function $name($parameters) { $assignments }';
    js.Template template = js.js.uncachedExpressionTemplate(code);
    return template.instantiate(const []);
  }

  Method _generateGetter(Field field) {
    String getterTemplateFor(int flags) {
      switch (flags) {
        case 1: return "function() { return this[#]; }";
        case 2: return "function(receiver) { return receiver[#]; }";
        case 3: return "function(receiver) { return this[#]; }";
      }
      return null;
    }

    js.Expression fieldName = js.string(field.name);
    js.Expression code = js.js(getterTemplateFor(field.getterFlags), fieldName);
    String getterName = "${namer.getterPrefix}${field.name}";
    return new StubMethod(getterName, code, needsTearOff: false);
  }

  Method _generateSetter(Field field) {
    String setterTemplateFor(int flags) {
      switch (flags) {
        case 1: return "function(val) { return this[#] = val; }";
        case 2: return "function(receiver, val) { return receiver[#] = val; }";
        case 3: return "function(receiver, val) { return this[#] = val; }";
      }
      return null;
    }
    js.Expression fieldName = js.string(field.name);
    js.Expression code = js.js(setterTemplateFor(field.setterFlags), fieldName);
    String setterName = "${namer.setterPrefix}${field.name}";
    return new StubMethod(setterName, code, needsTearOff: false);
  }

  Iterable<Method> _generateGettersSetters(Class cls) {
    Iterable<Method> getters = cls.fields
        .where((Field field) => field.needsGetter)
        .map(_generateGetter);

    Iterable<Method> setters = cls.fields
        .where((Field field) => field.needsUncheckedSetter)
        .map(_generateSetter);

    return [getters, setters].expand((x) => x);
  }

  // This string should be referenced wherever JavaScript code makes assumptions
  // on the mixin format.
  static final String mixinFormatDescription =
      "Mixins have no constructor, but a reference to their mixin class.";

  js.Expression emitClass(Class cls) {
    List elements = [js.string(cls.superclassName),
                     js.number(cls.superclassHolderIndex)];

    if (cls.isMixinApplication) {
      MixinApplication mixin = cls;
      elements.add(js.string(mixin.mixinClass.name));
      elements.add(js.number(mixin.mixinClass.holder.index));
    } else {
      elements.add(_generateConstructor(cls));
    }
    Iterable<Method> methods = cls.methods;
    Iterable<Method> isChecks = cls.isChecks;
    Iterable<Method> gettersSetters = _generateGettersSetters(cls);
    Iterable<Method> allMethods =
        [methods, isChecks, gettersSetters].expand((x) => x);
    elements.addAll(allMethods.expand((e) => [js.string(e.name), e.code]));
    return unparse(compiler, new js.ArrayInitializer(elements));
  }

  js.Expression emitLazyInitializer(StaticField field) {
    assert(field.isLazy);
    return unparse(compiler, field.code);
  }

  js.Expression emitStaticMethod(StaticMethod method) {
    return unparse(compiler, method.code);
  }

  static final String boilerplate = """
{
// Declare deferred-initializer global.
#deferredInitializer;

!function(start, program) {

  // Initialize holder objects.
  #holders;

  function setupProgram() {
    for (var i = 0; i < program.length - 1; i++) {
      setupLibrary(program[i]);
    }
    setupLazyStatics(program[i]);
  }

  function setupLibrary(library) {
    var statics = library[0];
    for (var i = 0; i < statics.length; i += 3) {
      var holderIndex = statics[i + 1];
      setupStatic(statics[i], holders[holderIndex], statics[i + 2]);
    }

    var classes = library[1];
    for (var i = 0; i < classes.length; i += 3) {
      var holderIndex = classes[i + 1];
      setupClass(classes[i], holders[holderIndex], classes[i + 2]);
    }
  }

  function setupLazyStatics(statics) {
    for (var i = 0; i < statics.length; i += 4) {
      var name = statics[i];
      var getterName = statics[i + 1];
      var holderIndex = statics[i + 2];
      var initializer = statics[i + 3];
      setupLazyStatic(name, getterName, holders[holderIndex], initializer);
    }
  }

  function setupStatic(name, holder, descriptor) {
    holder[name] = function() {
      var method = compile(name, descriptor);
      holder[name] = method;
      return method.apply(this, arguments);
    };
  }

  function setupLazyStatic(name, getterName, holder, descriptor) {
    holder[name] = null;
    holder[getterName] = function() {
      var initializer = compile(name, descriptor);
      holder[getterName] = function() { #cyclicThrow(name) };
      var result;
      var sentinelInProgress = descriptor;
      try {
        result = holder[name] = sentinelInProgress;
        result = holder[name] = initializer();
      } finally {
        // Use try-finally, not try-catch/throw as it destroys the stack trace.
        if (result === sentinelInProgress) {
          // The lazy static (holder[name]) might have been set to a different
          // value. According to spec we still have to reset it to null, if the
          // initialization failed.
          holder[name] = null;
        }
        holder[getterName] = function() { return this[name]; };
      }
      return result;
    };
  }

  function setupClass(name, holder, descriptor) {
    var ensureResolved = function() {
      var constructor = compileConstructor(name, descriptor);
      holder[name] = constructor;
      constructor.ensureResolved = function() { return this; };
      return constructor;
    };

    var patch = function() {
      var constructor = ensureResolved();
      var object = new constructor();
      constructor.apply(object, arguments);
      return object;
    };

    // We store the ensureResolved function on the patch function to make it
    // possible to resolve superclass references without constructing instances.
    patch.ensureResolved = ensureResolved;
    holder[name] = patch;
  }

  function compileConstructor(name, descriptor) {
    descriptor = compile(name, descriptor);
    var prototype = determinePrototype(descriptor);
    var constructor;
    // $mixinFormatDescription.
    if (typeof descriptor[2] !== 'function') {
      constructor = compileMixinConstructor(name, prototype, descriptor);
      for (var i = 4; i < descriptor.length; i += 2) {
        prototype[descriptor[i]] = descriptor[i + 1];
      }
    } else {
      constructor = descriptor[2];
      for (var i = 3; i < descriptor.length; i += 2) {
        prototype[descriptor[i]] = descriptor[i + 1];
      }
    }
    constructor.builtin\$cls = name;  // Needed for RTI.
    constructor.prototype = prototype;
    prototype.constructor = constructor;
    return constructor;
  }

  function compileMixinConstructor(name, prototype, descriptor) {
    // $mixinFormatDescription.
    var mixinName = descriptor[2];
    var mixinHolderIndex = descriptor[3];
    var mixin = holders[mixinHolderIndex][mixinName].ensureResolved();
    var mixinPrototype = mixin.prototype;

    // Fill the prototype with the mixin's properties.
    var mixinProperties = Object.keys(mixinPrototype);
    for (var i = 0; i < mixinProperties.length; i++) {
      var p = mixinProperties[i];
      prototype[p] = mixinPrototype[p];
    }
    // Since this is a mixin application the constructor will actually never
    // be invoked. We only use its prototype for the application's subclasses. 
    var constructor = function() {};
    return constructor;
  }

  function determinePrototype(descriptor) {
    var superclassName = descriptor[0];
    if (!superclassName) return { };

    // Look up the superclass constructor function in the right holder.
    var holderIndex = descriptor[1];
    var superclass = holders[holderIndex][superclassName].ensureResolved();

    // Create a new prototype object chained to the superclass prototype.
    var intermediate = function() { };
    intermediate.prototype = superclass.prototype;
    return new intermediate();
  }

  function compile(__name__, __s__) {
    'use strict';
    // TODO(floitsch): evaluate the performance impact of the string
    // concatenations.
    return eval(__s__ + "\\n//# sourceURL=" + __name__ + ".js");
  }

  if (#outputContainsConstantList) {
    function makeConstList(list) {
      // By assigning a function to the properties they become part of the
      // hidden class. The actual values of the fields don't matter, since we
      // only check if they exist.
      list.immutable\$list = Array;
      list.fixed\$length = Array;
      return list;
    }
  }

  setupProgram();

  // Initialize globals.
  #embeddedGlobals;

  // Initialize constants.
  #constants;

  // Initialize static non-final fields.
  #staticNonFinals;

  // Add native boilerplate code.
  #nativeBoilerplate;

  // Initialize eager classes.
  #eagerClasses;

  var end = Date.now();
  print('Setup: ' + (end - start) + ' ms.');

  #main();  // Start main.

}(Date.now(), #code)
}""";

}
