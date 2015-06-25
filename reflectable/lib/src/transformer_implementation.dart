// (c) 2015, the Dart Team. All rights reserved. Use of this
// source code is governed by a BSD-style license that can be found in
// the LICENSE file.

library reflectable.src.transformer_implementation;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show max;
import 'package:analyzer/src/generated/ast.dart';
import 'package:analyzer/src/generated/constant.dart';
import 'package:analyzer/src/generated/element.dart';
import 'package:barback/barback.dart';
import 'package:code_transformers/resolver.dart';
import 'element_capability.dart' as ec;
import 'encoding_constants.dart' as constants;
import "reflectable_class_constants.dart" as reflectable_class_constants;
import 'source_manager.dart';
import 'transformer_errors.dart' as errors;

class ReflectionWorld {
  final List<ReflectorDomain> reflectors = new List<ReflectorDomain>();
  final LibraryElement reflectableLibrary;

  ReflectionWorld(this.reflectableLibrary);

  Iterable<ReflectorDomain> reflectorsOfLibrary(LibraryElement library) {
    return reflectors.where((ReflectorDomain domain) {
      return domain.reflector.library == library;
    });
  }

  Iterable<ClassDomain> annotatedClassesOfLibrary(LibraryElement library) {
    return reflectors
        .expand((ReflectorDomain domain) => domain.annotatedClasses)
        .where((ClassDomain classDomain) {
      return classDomain.classElement.library == library;
    });
  }

  String generateCode() {
    String result = reflectors.map((ReflectorDomain reflector) {
      return "const ${reflector.reflector.name}(): ${reflector.generateCode()}";
    }).join(",  ");
    return "{$result}";
  }
}

/// Similar to a `Set<T>` but also keeps track of the index of the first
/// insertion of each item.
class Enumerator<T> {
  final Map<T, int> _map = new Map<T, int>();
  int _count = 0;

  get length => _count;

  /// Tries to insert [t]. If it was already there return false, else insert it
  /// and return true.
  bool add(T t) {
    if (_map.containsKey(t)) return false;
    _map[t] = _count;
    ++_count;
    return true;
  }

  /// Returns the index of a given item.
  int indexOf(T t) {
    return _map[t];
  }

  /// Returns all the items in the order they were inserted.
  Iterable<T> get items {
    return _map.keys;
  }
}

/// Information about the program parts that can be reflected by a given
/// Reflector.
class ReflectorDomain {
  final ClassElement reflector;
  final List<ClassDomain> annotatedClasses;
  final Map<ClassElement, ClassDomain> classMap =
      new Map<ClassElement, ClassDomain>();
  final Capabilities capabilities;

  /// Libraries that must be imported to `reflector.library`.
  final Set<LibraryElement> missingImports = new Set<LibraryElement>();

  ReflectorDomain(this.reflector, this.annotatedClasses, this.capabilities) {}

  // TODO(eernst, sigurdm): Perhaps reconsider what the best strategy for
  // caching is.
  Map<ClassElement, Map<String, ExecutableElement>> _instanceMemberCache =
      new Map<ClassElement, Map<String, ExecutableElement>>();

  /// Returns a string that evaluates to a closure invoking [constructor] with
  /// the given arguments.
  /// For example for a constructor Foo(x, {y: 3}):
  /// returns "(x, {y: 3}) => new Foo(x, y)".
  /// This is to provide something that can be called with [Function.apply].
  String constructorCode(ConstructorElement constructor) {
    FunctionType type = constructor.type;

    int requiredPositionalCount = type.normalParameterTypes.length;
    int optionalPositionalCount = type.optionalParameterTypes.length;

    List<String> parameterNames = type.parameters
        .map((ParameterElement parameter) => parameter.name)
        .toList();

    List<String> NamedParameterNames = type.namedParameterTypes.keys.toList();

    String positionals = new Iterable.generate(
        requiredPositionalCount, (int i) => parameterNames[i]).join(", ");

    String optionalsWithDefaults = new Iterable.generate(
        optionalPositionalCount, (int i) {
      String defaultValueCode =
          constructor.parameters[requiredPositionalCount + i].defaultValueCode;
      String defaultValueString =
          defaultValueCode == null ? "" : " = $defaultValueCode";
      return "${parameterNames[i + requiredPositionalCount]}"
          "$defaultValueString";
    }).join(", ");

    String namedWithDefaults = new Iterable.generate(NamedParameterNames.length,
        (int i) {
      // TODO(eernst, sigurdm, #8): Recreate the default values faithfully.
      // TODO(eernst, sigurdm, #8): Until that is done, recognize unhandled
      // cases, and emit error/warning.
      String defaultValueCode =
          constructor.parameters[requiredPositionalCount + i].defaultValueCode;
      String defaultValueString =
          defaultValueCode == null ? "" : ": $defaultValueCode";
      return "${NamedParameterNames[i]}$defaultValueString";
    }).join(", ");

    String optionalArguments = new Iterable.generate(optionalPositionalCount,
        (int i) => parameterNames[i + requiredPositionalCount]).join(", ");
    String namedArguments =
        NamedParameterNames.map((String name) => "$name: $name").join(", ");

    List<String> parameterParts = new List<String>();
    List<String> argumentParts = new List<String>();

    if (requiredPositionalCount != 0) {
      parameterParts.add(positionals);
      argumentParts.add(positionals);
    }
    if (optionalPositionalCount != 0) {
      parameterParts.add("[$optionalsWithDefaults]");
      argumentParts.add(optionalArguments);
    }
    if (NamedParameterNames.isNotEmpty) {
      parameterParts.add("{${namedWithDefaults}}");
      argumentParts.add(namedArguments);
    }

    return ('(${parameterParts.join(', ')}) => '
        'new ${nameOfDeclaration(constructor)}'
        '(${argumentParts.join(", ")})');
  }

  String formatList(Iterable parts) => "[${parts.join(", ")}]";

  String formatMap(Iterable parts) => "{${parts.join(", ")}}";

  String generateCode() {
    Enumerator<ExecutableElement> members = new Enumerator<MethodElement>();
    Enumerator<ClassElement> classes = new Enumerator<ClassElement>();
    Set<String> instanceGetterNames = new Set<String>();
    Set<String> instanceSetterNames = new Set<String>();

    for (ClassDomain classDomain in annotatedClasses) {
      classMap[classDomain.classElement] = classDomain;
    }
    for (ClassDomain classDomain in annotatedClasses) {
      classes.add(classDomain.classElement);
      classDomain.declarations.forEach(members.add);
      classDomain.instanceMembers.forEach(members.add);
      classDomain.instanceMembers.forEach((ExecutableElement instanceMember) {
        if (instanceMember is PropertyAccessorElement) {
          if (instanceMember.isGetter) {
            instanceGetterNames.add(instanceMember.name);
          } else {
            instanceSetterNames.add(instanceMember.name);
          }
        } else {
          instanceGetterNames.add(instanceMember.name);
        }
      });
    }

    String classMirrors = formatList(new Iterable<String>.generate(
        annotatedClasses.length, (int i) {
      ClassDomain classDomain = annotatedClasses[i];
      String declarationsCode = formatList(classDomain.declarations
          .map((ExecutableElement element) {
        return members.indexOf(element);
      }));

      String instanceMembersCode = formatList(classDomain.instanceMembers
          .map((ExecutableElement element) {
        return members.indexOf(element);
      }));

      ClassElement superclass = classDomain.classElement.supertype.element;
      String superclassIndex;
      if (superclass == null) {
        superclassIndex = null;
      } else {
        int index = classes.indexOf(superclass);
        if (index == null) {
          index = -1;
        }
        superclassIndex = "$index";
      }
      String metadataCode;
      if (capabilities.supportsMetadata) {
        metadataCode = classDomain.metadataCode;
      } else {
        metadataCode = "null";
      }
      return 'new r.ClassMirrorImpl("${classDomain.simpleName}", '
          '"${classDomain.qualifiedName}", $i, const ${reflector.name}(), '
          '$declarationsCode, $instanceMembersCode, $superclassIndex, '
          '$metadataCode)';
    }));
    String gettersCode = formatMap(instanceGetterNames.map((String methodName) {
      String closure;
      // TODO(eernst, sigurdm): Investigate generating specialized versions.
      if (methodName.startsWith(new RegExp(r"[A-Za-z$_]"))) {
        // Starts with letter, not an operator.
        closure = "(dynamic instance) => instance.${methodName}";
      } else if (methodName == "[]=") {
        closure = "(dynamic instance) => (x, v) => instance[x] = v";
      } else if (methodName == "[]") {
        closure = "(dynamic instance) => (x) => instance[x]";
      } else {
        closure = "(dynamic instance) => (x) => instance ${methodName} x";
      }
      return '"${methodName}": $closure';
    }));
    String settersCode = formatMap(instanceSetterNames.map((String setterName) {
      return '"${setterName}": '
          '(dynamic instance, dynamic value) => instance.${setterName} value';
    }));

    String methodsCode = formatList(members.items
        .map((ExecutableElement element) {
      int descriptor = _declarationDescriptor(element);
      int ownerIndex = classes.indexOf(element.enclosingElement);
      return 'new r.MethodMirrorImpl("${element.name}", $descriptor, '
          '$ownerIndex, const ${reflector.name}())';
    }));

    // TODO(sigurdm): Implement static functions.
    String staticMembersCode = "null";
    String typesCode = formatList(
        classes.items.map((ClassElement classElement) => classElement.name));
    String constructorsCode = formatMap(annotatedClasses
        .expand((ClassDomain classDomain) {
      if (classDomain.classElement.isAbstract) return [];
      return classDomain.constructors.map((ConstructorElement constructor) {
        String longName = "${classDomain.qualifiedName}.${constructor.name}";
        return '"$longName": ${constructorCode(constructor)}';
      });
    }));

    return "new r.ReflectorData($classMirrors, $methodsCode, "
        "$staticMembersCode, $typesCode, $constructorsCode, "
        "$gettersCode, $settersCode)";
  }
}

/// Information about reflectability for a given class.
class ClassDomain {
  final ClassElement classElement;
  final Iterable<MethodElement> declaredMethods;
  final Iterable<PropertyAccessorElement> declaredAccessors;
  final Iterable<ConstructorElement> constructors;

  ReflectorDomain reflectorDomain;

  ClassDomain(this.classElement, this.declaredMethods, this.declaredAccessors,
      this.constructors, this.reflectorDomain);

  Iterable<MethodElement> get invokableMethods => instanceMembers
      .where((ExecutableElement element) => element is MethodElement);

  String get simpleName => classElement.name;
  String get qualifiedName {
    return "${classElement.library.name}.${classElement.name}";
  }

  Iterable<ExecutableElement> get declarations {
    // TODO(sigurdm): Include fields.
    // TODO(sigurdm): Include type variables (if we decide to keep them).
    return [declaredMethods, declaredAccessors, constructors].expand((x) => x);
  }

  /// Finds all instance members by going through the class hierarchy.
  Iterable<ExecutableElement> get instanceMembers {
    Map<String, ExecutableElement> helper(ClassElement classElement) {
      if (reflectorDomain._instanceMemberCache[classElement] != null) {
        return reflectorDomain._instanceMemberCache[classElement];
      }
      Map<String, ExecutableElement> result =
          new Map<String, ExecutableElement>();

      void addIfCapable(ExecutableElement member) {
        if (reflectorDomain.capabilities.supportsInstanceInvoke(
            member.name, member.metadata)) {
          result[member.name] = member;
        }
      }
      if (classElement.supertype != null) {
        helper(classElement.supertype.element)
            .forEach((String name, ExecutableElement member) {
          addIfCapable(member);
        });
      }
      for (InterfaceType mixin in classElement.mixins) {
        helper(mixin.element).forEach((String name, ExecutableElement member) {
          addIfCapable(member);
        });
      }
      for (MethodElement member in classElement.methods) {
        if (member.isAbstract || member.isStatic) continue;
        addIfCapable(member);
      }
      for (PropertyAccessorElement member in classElement.accessors) {
        if (member.isAbstract || member.isStatic) continue;
        addIfCapable(member);
      }
      for (FieldElement field in classElement.fields) {
        if (field.isStatic) continue;
        if (field.isSynthetic) continue;
        addIfCapable(field.getter);
        if (!field.isFinal) {
          addIfCapable(field.setter);
        }
      }
      return result;
    }
    return helper(classElement).values;
  }

  /// Returns a String with the textual representations of the metadata list.
  // TODO(sigurdm, 17307): Make this less fragile when the analyzer's
  // element-model exposes the metadata in a more friendly way.
  String get metadataCode {
    List<String> metadataParts = new List<String>();
    Iterator<Annotation> nodeIterator = classElement.node.metadata.iterator;
    Iterator<ElementAnnotation> elementIterator =
        classElement.metadata.iterator;
    while (nodeIterator.moveNext()) {
      bool r = elementIterator.moveNext();
      assert(r);
      Annotation annotationNode = nodeIterator.current;
      ElementAnnotation elementAnnotation = elementIterator.current;
      // Remove the @-sign.
      String source = annotationNode.toSource().substring(1);
      if (elementAnnotation.element is ConstructorElement) {
        // If this is a constructor call, add the otherwise implicit 'const'.
        metadataParts.add("const $source");
      } else {
        metadataParts.add(source);
      }
    }
    return "[${metadataParts.join(", ")}]";
  }

  String toString() {
    return "ClassDomain(classElement)";
  }
}

/// A wrapper around a list of Capabilities.
/// Supports queries about the methods supported by the set of capabilities.
class Capabilities {
  List<ec.ReflectCapability> capabilities;
  Capabilities(this.capabilities);

  instanceMethodsFilterRegexpString() {
    if (capabilities.contains(ec.instanceInvokeCapability)) return ".*";
    if (capabilities.contains(ec.invokingCapability)) return ".*";
    return capabilities.where((ec.ReflectCapability capability) {
      return capability is ec.InstanceInvokeCapability;
    }).map((ec.InstanceInvokeCapability capability) {
      return "(${capability.namePattern})";
    }).join('|');
  }

  bool _supportsName(ec.NamePatternCapability capability, String methodName) {
    RegExp regexp = new RegExp(capability.namePattern);
    return regexp.firstMatch(methodName) != null;
  }

  bool _supportsMeta(ec.MetadataQuantifiedCapability capability,
      List<ElementAnnotation> metadata) {
    throw new UnimplementedError("Metadata comparison not yet supported");
  }

  bool _supportsInstanceInvoke(List<ec.ReflectCapability> capabilities,
      String methodName, List<ElementAnnotation> metadata) {

    // Handle API based capabilities.

    if (capabilities.contains(ec.invokingCapability)) return true;
    if (capabilities.contains(ec.instanceInvokeCapability)) return true;

    bool supportsInvoking(ec.ReflectCapability cap) =>
        cap is ec.InvokingCapability && _supportsName(cap, methodName);
    if (capabilities.any(supportsInvoking)) return true;

    bool supportsInstanceInvoke(ec.ReflectCapability cap) =>
        cap is ec.InstanceInvokeCapability && _supportsName(cap, methodName);
    if (capabilities.any(supportsInstanceInvoke)) return true;

    bool supportsInvokingMeta(ec.ReflectCapability cap) =>
        cap is ec.InvokingMetaCapability && _supportsMeta(cap, metadata);
    if (capabilities.any(supportsInvokingMeta)) return true;

    bool supportsInstanceInvokeMeta(ec.ReflectCapability cap) =>
        cap is ec.InstanceInvokeMetaCapability && _supportsMeta(cap, metadata);
    if (capabilities.any(supportsInstanceInvokeMeta)) return true;

    // Handle reflectee based capabilities.

    bool supportsTarget(ec.ReflecteeQuantifyCapability capability) {
      // TODO(eernst): implement this correctly; will need something
      // like this, which will cover the case where we have applied
      // the trivial subtype:
      return _supportsInstanceInvoke(
          capability.capabilities, methodName, metadata);
    }

    bool supportsSubtype(ec.ReflectCapability cap) =>
        cap is ec.SubtypeQuantifyCapability && supportsTarget(cap);
    if (capabilities.any(supportsSubtype)) return true;

    bool supportsAdmit(ec.ReflectCapability cap) =>
        cap is ec.AdmitSubtypeCapability && supportsTarget(cap);
    if (capabilities.any(supportsAdmit)) return true;

    // Handle globally quantified capabilities.

    // TODO(eernst): We probably need to refactor a lot of stuff
    // to get this right, so the first approach will simply be to
    // discover the relevant capabilities, and indicate that they
    // are not yet supported.
    capabilities.forEach((ec.ReflectCapability cap) {
      if (cap is ec.GlobalQuantifyCapability ||
          cap is ec.GlobalQuantifyMetaCapability) {
        throw new UnimplementedError("Global quantification not yet supported");
      }
    });

    // All options exhausted, give up.

    return false;
  }

  bool supportsInstanceInvoke(
      String methodName, List<ElementAnnotation> metadata) {
    return _supportsInstanceInvoke(capabilities, methodName, metadata);
  }

  bool _supportsStaticInvoke(List<ec.ReflectCapability> capabilities,
      String methodName, List<ElementAnnotation> metadata) {

    // Handle API based capabilities.

    if (capabilities.contains(ec.invokingCapability)) return true;
    if (capabilities.contains(ec.staticInvokeCapability)) return true;

    bool supportsInvoking(ec.ReflectCapability cap) =>
        cap is ec.InvokingCapability && _supportsName(cap, methodName);
    if (capabilities.any(supportsInvoking)) return true;

    bool supportsStaticInvoke(ec.ReflectCapability cap) =>
        cap is ec.StaticInvokeCapability && _supportsName(cap, methodName);
    if (capabilities.any(supportsStaticInvoke)) return true;

    bool supportsInvokingMeta(ec.ReflectCapability cap) =>
        cap is ec.InvokingMetaCapability && _supportsMeta(cap, metadata);
    if (capabilities.any(supportsInvokingMeta)) return true;

    bool supportsStaticInvokeMeta(ec.ReflectCapability cap) =>
        cap is ec.StaticInvokeMetaCapability && _supportsMeta(cap, metadata);
    if (capabilities.any(supportsStaticInvokeMeta)) return true;

    // Handle reflectee based capabilities.

    bool supportsTarget(ec.ReflecteeQuantifyCapability capability) {
      // TODO(eernst): implement this correctly.
      return _supportsStaticInvoke(
          capability.capabilities, methodName, metadata);
    }

    bool supportsSubtype(ec.ReflectCapability cap) =>
        cap is ec.SubtypeQuantifyCapability && supportsTarget(cap);
    if (capabilities.any(supportsSubtype)) return true;

    bool supportsAdmit(ec.ReflectCapability cap) =>
        cap is ec.AdmitSubtypeCapability && supportsTarget(cap);
    if (capabilities.any(supportsAdmit)) return true;

    // All options exhausted, give up.

    return false;
  }

  bool supportsStaticInvoke(
      String methodName, List<ElementAnnotation> metadata) {
    return _supportsStaticInvoke(capabilities, methodName, metadata);
  }

  bool get supportsMetadata {
    return capabilities.any((ec.ReflectCapability capability) =>
        capability == ec.metadataCapability);
  }
}

// TODO(eernst): Keep in mind, with reference to
// http://dartbug.com/21654 comment #5, that it would be very valuable
// if this transformation can interact smoothly with incremental
// compilation.  By nature, that is hard to achieve for a
// source-to-source translation scheme, but a long source-to-source
// translation step which is invoked frequently will certainly destroy
// the immediate feedback otherwise offered by incremental compilation.
// WORKAROUND: A work-around for this issue which is worth considering
// is to drop the translation entirely during most of development,
// because we will then simply work on a normal Dart program that uses
// dart:mirrors, which should have the same behavior as the translated
// program, and this could work quite well in practice, except for
// debugging which is concerned with the generated code (but that would
// ideally be an infrequent occurrence).

class TransformerImplementation {
  TransformLogger logger;
  Resolver resolver;

  /// Checks whether the given [type] from the target program is "our"
  /// class [Reflectable] by looking up the static field
  /// [Reflectable.thisClassId] and checking its value (which is a 40
  /// character string computed by sha1sum on an old version of
  /// reflectable.dart).
  ///
  /// Discussion of approach: Checking that we have found the correct
  /// [Reflectable] class is crucial for correctness, and the "obvious"
  /// approach of just looking up the library and then the class with the
  /// right names using [resolver] is unsafe.  The problems are as
  /// follows: (1) Library names are not guaranteed to be unique in a
  /// given program, so we might look up a different library named
  /// reflectable.reflectable, and a class named Reflectable in there.  (2)
  /// Library URIs (which must be unique in a given program) are not known
  /// across all usage locations for reflectable.dart, so we cannot easily
  /// predict all the possible URIs that could be used to import
  /// reflectable.dart; and it would be awkward to require that all user
  /// programs must use exactly one specific URI to import
  /// reflectable.dart.  So we use [Reflectable.thisClassId] which is very
  /// unlikely to occur with the same value elsewhere by accident.
  bool _equalsClassReflectable(ClassElement type) {
    FieldElement idField = type.getField("thisClassId");
    if (idField == null || !idField.isStatic) return false;
    if (idField is ConstFieldElementImpl) {
      EvaluationResultImpl idResult = idField.evaluationResult;
      if (idResult != null) {
        return idResult.value.stringValue == reflectable_class_constants.id;
      }
      // idResult == null: analyzer/.../element.dart does not specify
      // whether this could happen, but it is surely not the right
      // class, so we fall through.
    }
    // Not a const field, cannot be the right class.
    return false;
  }

  /// Returns the ClassElement in the target program which corresponds to class
  /// [Reflectable].
  ClassElement _findReflectableClassElement(LibraryElement reflectableLibrary) {
    for (CompilationUnitElement unit in reflectableLibrary.units) {
      for (ClassElement type in unit.types) {
        if (type.name == reflectable_class_constants.name &&
            _equalsClassReflectable(type)) {
          return type;
        }
      }
    }
    // Class [Reflectable] was not found in the target program.
    return null;
  }

  /// Returns true iff [possibleSubtype] is a direct subclass of [type].
  bool _isDirectSubclassOf(InterfaceType possibleSubtype, InterfaceType type) {
    InterfaceType superclass = possibleSubtype.superclass;
    // Even if `superclass == null` (superclass of Object), the equality
    // test will produce the correct result.
    return type == superclass;
  }

  /// Returns true iff [possibleSubtype] is a subclass of [type], including the
  /// reflexive and transitive cases.
  bool _isSubclassOf(InterfaceType possibleSubtype, InterfaceType type) {
    if (possibleSubtype == type) return true;
    InterfaceType superclass = possibleSubtype.superclass;
    if (superclass == null) return false;
    return _isSubclassOf(superclass, type);
  }

  /// Returns the metadata class in [elementAnnotation] if it is an
  /// instance of a direct subclass of [focusClass], otherwise returns
  /// `null`.  Uses [errorReporter] to report an error if it is a subclass
  /// of [focusClass] which is not a direct subclass of [focusClass],
  /// because such a class is not supported as a Reflector.
  ClassElement _getReflectableAnnotation(
      ElementAnnotation elementAnnotation, ClassElement focusClass) {
    if (elementAnnotation.element == null) {
      // TODO(eernst): The documentation in
      // analyzer/lib/src/generated/element.dart does not reveal whether
      // elementAnnotation.element can ever be null. The following action
      // is based on the assumption that it means "there is no annotation
      // here anyway".
      return null;
    }

    /// Checks that the inheritance hierarchy placement of [type]
    /// conforms to the constraints relative to [classReflectable],
    /// which is intended to refer to the class Reflectable defined
    /// in package:reflectable/reflectable.dart. In case of violations,
    /// reports an error on [logger].
    bool checkInheritance(InterfaceType type, InterfaceType classReflectable) {
      if (!_isSubclassOf(type, classReflectable)) {
        // Not a subclass of [classReflectable] at all.
        return false;
      }
      if (!_isDirectSubclassOf(type, classReflectable)) {
        // Instance of [classReflectable], or of indirect subclass
        // of [classReflectable]: Not supported, report an error.
        logger.error(errors.METADATA_NOT_DIRECT_SUBCLASS,
            span: resolver.getSourceSpan(elementAnnotation.element));
        return false;
      }
      // A direct subclass of [classReflectable], all OK.
      return true;
    }

    Element element = elementAnnotation.element;
    // TODO(eernst): Currently we only handle constructor expressions
    // and simple identifiers.  May be generalized later.
    if (element is ConstructorElement) {
      bool isOk =
          checkInheritance(element.enclosingElement.type, focusClass.type);
      return isOk ? element.enclosingElement.type.element : null;
    } else if (element is PropertyAccessorElement) {
      PropertyInducingElement variable = element.variable;
      // Surprisingly, we have to use [ConstTopLevelVariableElementImpl]
      // here (or a similar type).  This is because none of the "public name"
      // types (types whose name does not end in `..Impl`) declare the getter
      // `evaluationResult`.  Another possible choice of type would be
      // [VariableElementImpl], but with that one we would have to test
      // `isConst` as well.
      if (variable is ConstTopLevelVariableElementImpl) {
        EvaluationResultImpl result = variable.evaluationResult;
        bool isOk = checkInheritance(result.value.type, focusClass.type);
        return isOk ? result.value.type.element : null;
      } else {
        // Not a const top level variable, not relevant.
        return null;
      }
    }
    // Otherwise [element] is some other construct which is not supported.
    //
    // TODO(eernst): We need to consider whether there could be some other
    // syntactic constructs that are incorrectly assumed by programmers to
    // be usable with Reflectable.  Currently, such constructs will silently
    // have no effect; it might be better to emit a diagnostic message (a
    // hint?) in order to notify the programmer that "it does not work".
    // The trade-off is that such constructs may have been written by
    // programmers who are doing something else, intentionally.  To emit a
    // diagnostic message, we must check whether there is a Reflectable
    // somewhere inside this syntactic construct, and then emit the message
    // in cases that we "consider likely to be misunderstood".
    return null;
  }

  Iterable<MethodElement> declaredMethods(
      ClassElement classElement, Capabilities capabilities) {
    return classElement.methods.where((MethodElement method) {
      if (method.isStatic) {
        // TODO(sigurdm): Ask capabilities about support.
        return true;
      } else {
        return capabilities.supportsInstanceInvoke(
            method.name, method.metadata);
      }
    });
  }

  Iterable<PropertyAccessorElement> declaredAccessors(
      ClassElement classElement, Capabilities capabilities) {
    return classElement.accessors.where((PropertyAccessorElement accessor) {
      if (accessor.isStatic) {
        // TODO(sigurdm): Ask capabilities about support.
        return true;
      } else {
        return capabilities.supportsInstanceInvoke(
            accessor.name, accessor.metadata);
      }
    });
  }

  Iterable<ConstructorElement> declaredConstructors(
      ClassElement classElement, Capabilities capabilities) {
    return classElement.constructors.where((ConstructorElement constructor) {
      // TODO(sigurdm): Ask capabilities about support.
      return true;
    });
  }

  /// Returns a [ReflectionWorld] instantiated with all the reflectors seen by
  /// [resolver] and all classes annotated by them.
  ///
  /// TODO(eernst): Make sure it works also when other packages are being
  /// used by the target program which have already been transformed by
  /// this transformer (e.g., there would be a clash on the use of
  /// reflectableClassId with values near 1000 for more than one class).
  ReflectionWorld _computeWorld(LibraryElement reflectableLibrary) {
    ReflectionWorld world = new ReflectionWorld(reflectableLibrary);
    Map<ClassElement, ReflectorDomain> domains =
        new Map<ClassElement, ReflectorDomain>();
    ClassElement focusClass = _findReflectableClassElement(reflectableLibrary);
    if (focusClass == null) {
      return null;
    }
    LibraryElement capabilityLibrary =
        resolver.getLibraryByName("reflectable.capability");
    for (LibraryElement library in resolver.libraries) {
      for (CompilationUnitElement unit in library.units) {
        for (ClassElement type in unit.types) {
          for (ElementAnnotation metadatum in type.metadata) {
            ClassElement reflector =
                _getReflectableAnnotation(metadatum, focusClass);
            if (reflector == null) continue;
            ReflectorDomain domain = domains.putIfAbsent(reflector, () {
              Capabilities capabilities =
                  _capabilitiesOf(capabilityLibrary, reflector);
              return new ReflectorDomain(
                  reflector, new List<ClassDomain>(), capabilities);
            });
            List<MethodElement> declaredMethodsOfClass =
                declaredMethods(type, domain.capabilities).toList();
            List<PropertyAccessorElement> declaredAccessorsOfClass =
                declaredAccessors(type, domain.capabilities).toList();
            List<ConstructorElement> declaredConstructorsOfClass =
                declaredConstructors(type, domain.capabilities).toList();
            domain.annotatedClasses.add(new ClassDomain(type,
                declaredMethodsOfClass, declaredAccessorsOfClass,
                declaredConstructorsOfClass, domain));
          }
        }
      }
    }
    domains.values.forEach(_collectMissingImports);

    world.reflectors.addAll(domains.values.toList());
    return world;
  }

  /// Finds all the libraries of classes annotated by the `domain.reflector`,
  /// thus specifying which `import` directives we
  /// need to add during code transformation.
  /// These are added to `domain.missingImports`.
  void _collectMissingImports(ReflectorDomain domain) {
    LibraryElement metadataLibrary = domain.reflector.library;
    for (ClassDomain classData in domain.annotatedClasses) {
      LibraryElement annotatedLibrary = classData.classElement.library;
      if (metadataLibrary != annotatedLibrary) {
        domain.missingImports.add(annotatedLibrary);
      }
    }
  }

  static const String generatedComment = "// Generated";

  ImportElement _findLastImport(LibraryElement library) {
    if (library.imports.isNotEmpty) {
      ImportElement importElement = library.imports.lastWhere(
          (importElement) => importElement.node != null, orElse: () => null);
      if (importElement != null) {
        // Found an import element with a node (i.e., a non-synthetic one).
        return importElement;
      } else {
        // No non-synthetic imports.
        return null;
      }
    }
    // library.imports.isEmpty
    return null;
  }

  ExportElement _findFirstExport(LibraryElement library) {
    if (library.exports.isNotEmpty) {
      ExportElement exportElement = library.exports.firstWhere(
          (exportElement) => exportElement.node != null, orElse: () => null);
      if (exportElement != null) {
        // Found an export element with a node (i.e., a non-synthetic one)
        return exportElement;
      } else {
        // No non-synthetic exports.
        return null;
      }
    }
    // library.exports.isEmpty
    return null;
  }

  /// Find a suitable index for insertion of additional import directives
  /// into [targetLibrary].
  int _newImportIndex(LibraryElement targetLibrary) {
    // Index in [source] where the new import directive is inserted, we
    // use 0 as the default placement (at the front of the file), but
    // make a heroic attempt to find a better placement first.
    int index = 0;
    ImportElement importElement = _findLastImport(targetLibrary);
    if (importElement != null) {
      index = importElement.node.end;
    } else {
      // No non-synthetic import directives present.
      ExportElement exportElement = _findFirstExport(targetLibrary);
      if (exportElement != null) {
        // Put the new import before the exports
        index = exportElement.node.offset;
      } else {
        // No non-synthetic import nor export directives present.
        LibraryDirective libraryDirective =
            targetLibrary.definingCompilationUnit.node.directives.firstWhere(
                (directive) => directive is LibraryDirective,
                orElse: () => null);
        if (libraryDirective != null) {
          // Put the new import after the library name directive.
          index = libraryDirective.end;
        } else {
          // No library directive either, keep index == 0.
        }
      }
    }
    return index;
  }

  /// Perform some very simple steps that are consistent with Dart
  /// semantics for the evaluation of constant expressions, such that
  /// information about the value of a given `const` variable can be
  /// obtained.  It is intended to help recognizing values of type
  /// [ReflectCapability], so we only cover cases needed for that.
  /// In particular, we cover lookup (e.g., with `const x = e` we can
  /// see that the value of `x` is `e`, and that step may be repeated
  /// if `e` is an [Identifier], or in general if it has a shape that
  /// is covered); similarly, `C.y` is evaluated to `42` if `C` is a
  /// class containing a declaration like `static const y = 42`. We do
  /// not perform any kind of arithmetic simplification.
  ///
  /// [context] is for error-reporting
  Expression _constEvaluate(Expression expression) {
    // [Identifier] can be [PrefixedIdentifier] and [SimpleIdentifier]
    // (and [LibraryIdentifier], but that is only used in [PartOfDirective],
    // so even when we use a library prefix like in `myLibrary.MyClass` it
    // will be a [PrefixedIdentifier] containing two [SimpleIdentifier]s).
    if (expression is SimpleIdentifier) {
      if (expression.staticElement is PropertyAccessorElement) {
        PropertyAccessorElement propertyAccessor = expression.staticElement;
        PropertyInducingElement variable = propertyAccessor.variable;
        // We expect to be called only on `const` expressions.
        if (!variable.isConst) {
          logger.error(errors.SUPER_ARGUMENT_NON_CONST,
              span: resolver.getSourceSpan(expression.staticElement));
        }
        VariableDeclaration variableDeclaration = variable.node;
        return _constEvaluate(variableDeclaration.initializer);
      }
    }
    if (expression is PrefixedIdentifier) {
      SimpleIdentifier simpleIdentifier = expression.identifier;
      if (simpleIdentifier.staticElement is PropertyAccessorElement) {
        PropertyAccessorElement propertyAccessor =
            simpleIdentifier.staticElement;
        PropertyInducingElement variable = propertyAccessor.variable;
        // We expect to be called only on `const` expressions.
        if (!variable.isConst) {
          logger.error(errors.SUPER_ARGUMENT_NON_CONST,
              span: resolver.getSourceSpan(expression.staticElement));
        }
        VariableDeclaration variableDeclaration = variable.node;
        return _constEvaluate(variableDeclaration.initializer);
      }
    }
    // No evaluation steps succeeded, return [expression] unchanged.
    return expression;
  }

  /// Returns the [ReflectCapability] denoted by the given [initializer].
  ec.ReflectCapability _capabilityOfExpression(
      LibraryElement capabilityLibrary, Expression expression) {
    Expression evaluatedExpression = _constEvaluate(expression);

    DartType dartType = evaluatedExpression.bestType;
    // The AST must have been resolved at this point.
    assert(dartType != null);

    // We insist that the type must be a class, and we insist that it must
    // be in the given `capabilityLibrary` (because we could never know
    // how to interpret the meaning of a user-written capability class, so
    // users cannot write their own capability classes).
    if (dartType.element is! ClassElement) {
      if (dartType.element.source != null) {
        logger.error(errors.applyTemplate(errors.SUPER_ARGUMENT_NON_CLASS, {
          "type": dartType.displayName
        }), span: resolver.getSourceSpan(dartType.element));
      } else {
        logger.error(errors.applyTemplate(
            errors.SUPER_ARGUMENT_NON_CLASS, {"type": dartType.displayName}));
      }
    }
    ClassElement classElement = dartType.element;
    if (classElement.library != capabilityLibrary) {
      logger.error(errors.applyTemplate(errors.SUPER_ARGUMENT_WRONG_LIBRARY, {
        "library": capabilityLibrary,
        "element": classElement
      }), span: resolver.getSourceSpan(classElement));
    }

    ec.ReflectCapability processInstanceCreationFromString(
        InstanceCreationExpression expression, String expectedConstructorName,
        ec.ReflectCapability defaultCapability,
        ec.ReflectCapability factory(String arg)) {
      // The [expression] came from a static evaluation of a const,
      // could never be a non-const.
      assert(expression.isConst);
      // We do not invoke some other constructor (in that case
      // [expression] would have had a different type).
      assert(expression.constructorName == expectedConstructorName);
      // There is only one constructor in that class, with one argument.
      assert(expression.argumentList.length == 1);
      Expression argument =
          _constEvaluate(expression.argumentList.arguments[0]);
      if (argument is SimpleStringLiteral) {
        if (argument.value == "") return defaultCapability;
        return factory(argument.value);
      }
      // TODO(eernst): Deny support for all other kinds of arguments, or
      // implement some more cases.
      throw new UnimplementedError("$expression not yet supported!");
    }

    ec.ReflectCapability processInstanceCreationFromOther(
        InstanceCreationExpression expression, String expectedConstructorName,
        ec.ReflectCapability defaultCapability,
        ec.ReflectCapability factory(arg)) {
      // The [expression] came from a static evaluation of a const,
      // could never be a non-const.
      assert(expression.isConst);
      // We do not invoke some other constructor (in that case
      // [expression] would have had a different type).
      assert(expression.constructorName == expectedConstructorName);
      // There is only one constructor in that class, with one argument.
      assert(expression.argumentList.length == 1);
      Expression argument =
          _constEvaluate(expression.argumentList.arguments[0]);
      if (argument is NullLiteral) return defaultCapability;
      return factory(argument);
    }

    switch (classElement.name) {
      case "_NameCapability":
        return ec.nameCapability;
      case "_ClassifyCapability":
        return ec.classifyCapability;
      case "_MetadataCapability":
        return ec.metadataCapability;
      case "_TypeRelationsCapability":
        return ec.typeRelationsCapability;
      case "_OwnerCapability":
        return ec.ownerCapability;
      case "_DeclarationsCapability":
        return ec.declarationsCapability;
      case "_UriCapability":
        return ec.uriCapability;
      case "_LibraryDependenciesCapability":
        return ec.libraryDependenciesCapability;

      case "InstanceInvokeCapability":
        if (evaluatedExpression is SimpleIdentifier &&
            evaluatedExpression.name == "instanceInvokeCapability") {
          return ec.instanceInvokeCapability;
        }
        // In simple cases, the [evaluatedExpression] is directly an
        // invocation of the constructor in this class.
        if (evaluatedExpression is InstanceCreationExpression) {
          return processInstanceCreationFromString(evaluatedExpression,
              "InstanceInvokeCapability", ec.instanceInvokeCapability,
              (String arg) => new ec.InstanceInvokeCapability(arg));
        }
        // TODO(eernst): other cases
        throw new UnimplementedError("$expression not yet supported!");
      case "InstanceInvokeMetaCapability":
        // TODO(eernst)
        throw new UnimplementedError("$classElement not yet supported!");
      case "StaticInvokeCapability":
        if (evaluatedExpression is SimpleIdentifier &&
            evaluatedExpression.name == "staticInvokeCapability") {
          return ec.staticInvokeCapability;
        }
        // In simple cases, the [evaluatedExpression] is directly an
        // invocation of the constructor in this class.
        if (evaluatedExpression is InstanceCreationExpression) {
          return processInstanceCreationFromString(evaluatedExpression,
              "StaticInvokeCapability", ec.staticInvokeCapability,
              (String arg) => new ec.StaticInvokeCapability(arg));
        }
        // TODO(eernst): other cases
        throw new UnimplementedError("$expression not yet supported!");
      case "StaticInvokeMetaCapability":
        // TODO(eernst)
        throw new UnimplementedError("$classElement not yet supported!");
      case "NewInstanceCapability":
        if (evaluatedExpression is SimpleIdentifier &&
            evaluatedExpression.name == "newInstanceCapability") {
          return ec.newInstanceCapability;
        }
        // In simple cases, the [evaluatedExpression] is directly an
        // invocation of the constructor in this class.
        if (evaluatedExpression is InstanceCreationExpression) {
          return processInstanceCreationFromString(evaluatedExpression,
              "NewInstanceCapability", ec.newInstanceCapability,
              (arg) => new ec.NewInstanceCapability(arg));
        }
        // TODO(eernst): other cases
        throw new UnimplementedError("$expression not yet supported!");
      case "NewInstanceMetaCapability":
        // TODO(eernst)
        throw new UnimplementedError("$classElement not yet supported!");
      case "TypeCapability":
        if (evaluatedExpression is SimpleIdentifier &&
            evaluatedExpression.name == "typeCapability") {
          return ec.typeCapability;
        }
        if (evaluatedExpression is SimpleIdentifier &&
            evaluatedExpression.name == "localTypeCapability") {
          return ec.localTypeCapability;
        }
        // In simple cases, the [evaluatedExpression] is directly an
        // invocation of the constructor in this class.
        if (evaluatedExpression is InstanceCreationExpression) {
          return processInstanceCreationFromOther(evaluatedExpression,
              "TypeCapability", ec.localTypeCapability,
              (arg) {
                if (arg is SimpleIdentifier) {
                  if (arg.name == "Object") return ec.typeCapability;
                  new ec.TypeCapability(arg.staticElement);
                }
                // TODO(eernst): other cases.
                throw new UnimplementedError(
                    "TypeCapability(..) only supported with Object or null!");
              });
        }
        // TODO(eernst): other cases.

        // TODO(eernst): problem, how can we create a Type object
        // corresponding to the one denoted by part of the given
        // evaluatedExpression?
        throw new UnimplementedError(
            "$classElement with an argument not yet supported!");
      case "InvokingCapability":
        if (evaluatedExpression is SimpleIdentifier &&
            evaluatedExpression.name == "invokingCapability") {
          return ec.invokingCapability;
        }
        // In simple cases, the [evaluatedExpression] is directly an
        // invocation of the constructor in this class.
        if (evaluatedExpression is InstanceCreationExpression) {
          return processInstanceCreationFromString(evaluatedExpression,
              "InvokingCapability", ec.invokingCapability,
              (String arg) => new ec.InvokingCapability(arg));
        }
        // TODO(eernst): other cases.
        throw new UnimplementedError("$classElement not yet supported!");
      case "InvokingMetaCapability":
        // TODO(eernst)
        throw new UnimplementedError("$classElement not yet supported!");
      case "TypingCapability":
        // TODO(eernst)
        throw new UnimplementedError("$classElement not yet supported!");
      case "SubtypeQuantifyCapability":
        // TODO(eernst)
        throw new UnimplementedError("$classElement not yet supported!");
      case "AdmitSubtypeCapability":
        // TODO(eernst)
        throw new UnimplementedError("$classElement not yet supported!");
      case "GlobalQuantifyCapability":
        // TODO(eernst)
        throw new UnimplementedError("$classElement not yet supported!");
      case "GlobalQuantifyMetaCapability":
        // TODO(eernst)
        throw new UnimplementedError("$classElement not yet supported!");
      default:
        throw new UnimplementedError("Unexpected capability $classElement");
    }
  }

  /// Returns the list of Capabilities given given as a superinitializer by the
  /// reflector.
  Capabilities _capabilitiesOf(
      LibraryElement capabilityLibrary, ClassElement reflector) {
    List<ConstructorElement> constructors = reflector.constructors;
    // The superinitializer must be unique, so there must be 1 constructor.
    assert(constructors.length == 1);
    ConstructorElement constructorElement = constructors[0];
    // It can only be a const constructor, because this class has been
    // used for metadata; it is a bug in the transformer if not.
    // It must also be a default constructor.
    assert(constructorElement.isConst);
    // TODO(eernst): Ensure that some other location in this transformer
    // checks that the reflector class constructor is indeed a default
    // constructor, such that this can be a mere assertion rather than
    // a user-oriented error report.
    assert(constructorElement.isDefaultConstructor);
    NodeList<ConstructorInitializer> initializers =
        constructorElement.node.initializers;

    if (initializers.length == 0) {
      // Degenerate case: Without initializers, we will obtain a reflector
      // without any capabilities, which is not useful in practice. We do
      // have this degenerate case in tests "just because we can", and
      // there is no technical reason to prohibit it, so we will handle
      // it here.
      return new Capabilities(<ec.ReflectCapability>[]);
    }
    // TODO(eernst): Ensure again that this can be a mere assertion.
    assert(initializers.length == 1);

    // Main case: the initializer is exactly one element. We must
    // handle two cases: `super(..)` and `super.fromList(<_>[..])`.
    SuperConstructorInvocation superInvocation = initializers[0];

    ec.ReflectCapability capabilityOfExpression(Expression expression) {
      return _capabilityOfExpression(capabilityLibrary, expression);
    }

    if (superInvocation.constructorName == null) {
      // Subcase: `super(..)` where 0..k arguments are accepted for some
      // k that we need not worry about here.
      NodeList<Expression> arguments = superInvocation.argumentList.arguments;
      return new Capabilities(arguments.map(capabilityOfExpression).toList());
    }
    assert(superInvocation.constructorName == "fromList");

    // Subcase: `super.fromList(const <..>[..])`.
    NodeList<Expression> arguments = superInvocation.argumentList.arguments;
    assert(arguments.length == 1);
    ListLiteral listLiteral = arguments[0];
    NodeList<Expression> expressions = listLiteral.elements;
    return new Capabilities(expressions.map(capabilityOfExpression).toList());
  }

  /// Returns the source of the file containing the reflection data for [world].
  /// [id] is used to create relative import uris.
  String reflectionWorldSource(ReflectionWorld world, AssetId id) {
    String reflectorImports = world.reflectors.map((ReflectorDomain reflector) {
      Uri uri = resolver.getImportUri(reflector.reflector.library, from: id);
      return "import '$uri';";
    }).join('\n');
    String reflectedImports = world.reflectors
        .expand((ReflectorDomain reflector) => reflector.annotatedClasses)
        .map((ClassDomain classDomain) {
      Uri uri =
          resolver.getImportUri(classDomain.classElement.library, from: id);
      return "import '$uri';";
    }).join('\n');
    // TODO(sigurdm): mirrors_unimpl.dart should be imported with a prefix.
    return """
library ${id.path.replaceAll("/", ".")};
import "package:reflectable/src/mirrors_unimpl.dart" as r;
$reflectorImports
$reflectedImports

initializeReflectable() {
  r.data = ${world.generateCode()};
}
""";
  }

  resetUsedNames() {}

  String transformMain(
      Asset entryPoint, String source, String reflectWorldUri) {
    // Used to manage replacements of code snippets by other code snippets
    // in [source].
    SourceManager sourceManager = new SourceManager(source);
    sourceManager.insert(
        0, "// This file has been transformed by reflectable.\n");
    LibraryElement mainLibrary = resolver.getLibrary(entryPoint.id);
    sourceManager.insert(_newImportIndex(mainLibrary),
        '\nimport "$reflectWorldUri" show initializeReflectable;');

    // TODO(eernst, sigurdm): This won't work if main is not declared in
    // `mainLibrary`.
    if (mainLibrary.entryPoint == null) {
      logger.warning("Could not find a main method in $entryPoint. Skipping.");
      return source;
    }
    sourceManager.insert(mainLibrary.entryPoint.nameOffset, "_");
    String args = (mainLibrary.entryPoint.parameters.length == 0) ? "" : "args";
    sourceManager.insert(source.length, """
void main($args) {
  initializeReflectable();
  _main($args);
}""");
    return sourceManager.source;
  }

  /// Performs the transformation which eliminates all imports of
  /// `package:reflectable/reflectable.dart` and instead provides a set of
  /// statically generated mirror classes.
  Future apply(
      AggregateTransform aggregateTransform, List<String> entryPoints) async {
    logger = aggregateTransform.logger;
    // The type argument in the return type is omitted because the
    // documentation on barback and on transformers do not specify it.
    Resolvers resolvers = new Resolvers(dartSdkDirectory);

    List<Asset> assets = await aggregateTransform.primaryInputs.toList();

    if (assets.isEmpty) {
      // It is a warning, not an error, to have nothing to transform.
      logger.warning("Warning: Nothing to transform");
      // Terminate with a non-failing status code to the OS.
      exit(0);
    }

    for (String entryPoint in entryPoints) {
      // Find the asset corresponding to [entryPoint]
      Asset entryPointAsset = assets.firstWhere(
          (Asset asset) => asset.id.path.endsWith(entryPoint),
          orElse: () => null);
      if (entryPointAsset == null) {
        aggregateTransform.logger
            .warning("Error: Missing entry point: $entryPoint");
        continue;
      }
      Transform wrappedTransform =
          new AggregateTransformWrapper(aggregateTransform, entryPointAsset);
      resetUsedNames(); // Each entry point has a closed world.

      resolver = await resolvers.get(wrappedTransform);
      LibraryElement reflectableLibrary =
          resolver.getLibraryByName("reflectable.reflectable");
      if (reflectableLibrary == null) {
        // Stop and do not consumePrimary, i.e., let the original source
        // pass through without changes.
        continue;
      }
      ReflectionWorld world = _computeWorld(reflectableLibrary);
      if (world == null) continue;

      String source = await entryPointAsset.readAsString();
      AssetId dataId =
          entryPointAsset.id.changeExtension("_reflection_data.dart");
      aggregateTransform.addOutput(
          new Asset.fromString(dataId, reflectionWorldSource(world, dataId)));

      String dataFileName = dataId.path.split('/').last;
      aggregateTransform.addOutput(new Asset.fromString(entryPointAsset.id,
          transformMain(entryPointAsset, source, dataFileName)));
      resolver.release();
    }
  }
}

/// Wrapper of `AggregateTransform` of type `Transform`, allowing us to
/// get a `Resolver` for a given `AggregateTransform` with a given
/// selection of a primary entry point.
/// TODO(eernst): We will just use this temporarily; code_transformers
/// may be enhanced to support a variant of Resolvers.get that takes an
/// [AggregateTransform] and an [Asset] rather than a [Transform], in
/// which case we can drop this class and use that method.
class AggregateTransformWrapper implements Transform {
  final AggregateTransform _aggregateTransform;
  final Asset primaryInput;
  AggregateTransformWrapper(this._aggregateTransform, this.primaryInput);
  TransformLogger get logger => _aggregateTransform.logger;
  Future<Asset> getInput(AssetId id) => _aggregateTransform.getInput(id);
  Future<String> readInputAsString(AssetId id, {Encoding encoding}) {
    return _aggregateTransform.readInputAsString(id, encoding: encoding);
  }
  Stream<List<int>> readInput(AssetId id) => _aggregateTransform.readInput(id);
  Future<bool> hasInput(AssetId id) => _aggregateTransform.hasInput(id);
  void addOutput(Asset output) => _aggregateTransform.addOutput(output);
  void consumePrimary() => _aggregateTransform.consumePrimary(primaryInput.id);
}

/// Returns an integer encoding the kind and attributes of the given
/// method/constructor/getter/setter.
int _declarationDescriptor(ExecutableElement element) {
  int result;
  if (element is PropertyAccessorElement) {
    result = element.isGetter ? constants.getter : constants.setter;
  } else if (element is ConstructorElement) {
    if (element.isFactory) {
      result = constants.factoryConstructor;
    } else {
      result = constants.generativeConstructor;
    }
    if (element.isConst) {
      result += constants.constAttribute;
    }
    if (element.redirectedConstructor != null) {
      result += constants.redirectingConstructor;
    }
  } else {
    result = constants.method;
  }
  if (element.isPrivate) {
    result += constants.privateAttribute;
  }
  if (element.isStatic) {
    result += constants.staticAttribute;
  }
  if (element.isSynthetic) {
    result += constants.syntheticAttribute;
  }
  if (element.isAbstract) {
    result += constants.abstractAttribute;
  }
  return result;
}

String nameOfDeclaration(ExecutableElement element) {
  if (element is ConstructorElement) {
    return element.name == ""
        ? element.enclosingElement.name
        : "${element.enclosingElement.name}.${element.name}";
  }
  return element.name;
}
