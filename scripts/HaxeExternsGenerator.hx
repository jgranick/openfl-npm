import haxe.macro.TypedExprTools;
import haxe.macro.ExprTools;
import sys.FileSystem;
import sys.io.File;
import haxe.io.Path;
import haxe.macro.Compiler;
import haxe.macro.Type;
import haxe.macro.Type.BaseType;
import haxe.macro.Type.AbstractType;
import haxe.macro.Context;

class HaxeExternsGenerator {
	private static final ALWAYS_ALLOWED_REFERENCE_TYPES = [
		"Any",
		"Array",
		"Bool",
		"Class",
		"Date",
		"Dynamic",
		"Float",
		"Int",
		"String",
		"UInt",
		"Void"
	];
	private static final eregAccessor = ~/^(g|s)et_[\w]+$/;

	public static function generate(?options:HaxeGeneratorOptions):Void {
		var outputDirPath = Path.join([Path.directory(Compiler.getOutput()), "as3-externs"]);
		if (options != null && options.outputPath != null) {
			outputDirPath = options.outputPath;
		}
		if (!Path.isAbsolute(outputDirPath)) {
			outputDirPath = Path.join([Sys.getCwd(), outputDirPath]);
		}
		Context.onGenerate(types -> {
			var generator = new HaxeExternsGenerator(options);
			generator.generateForTypes(types, outputDirPath);
		});
	}

	private var options:HaxeGeneratorOptions;

	private function new(?options:HaxeGeneratorOptions) {
		this.options = options;
	}

	public function generateForTypes(types:Array<Type>, outputDirPath:String):Void {
		for (type in types) {
			switch (type) {
				case TInst(t, params):
					var classType = t.get();
					if (shouldSkipBaseType(classType, false)) {
						continue;
					}
					if (classType.isInterface) {
						var generated = generateInterface(classType, params);
						writeGenerated(outputDirPath, classType, generated);
					} else {
						var generated = generateClass(classType, params);
						writeGenerated(outputDirPath, classType, generated);
					}
				case TEnum(t, params):
					var enumType = t.get();
					if (shouldSkipBaseType(enumType, false)) {
						continue;
					}
					var generated = generateEnum(enumType, params);
					writeGenerated(outputDirPath, enumType, generated);
				case TAbstract(t, params):
					var abstractType = t.get();
					if (shouldSkipBaseType(abstractType, false)) {
						continue;
					}
					if (!abstractType.meta.has(":enum")) {
						// ignore non-enum abstracts because they don't exist in openfl-js
						continue;
					}
					var generated = generateAbstractEnum(abstractType, params);
					writeGenerated(outputDirPath, abstractType, generated);
				case TType(t, params):
					// ignore typedefs because they don't exist in openfl-js
				default:
					trace("Unexpected type: " + type);
			}
		}
	}

	private function isInPackage(expected:Array<String>, actual:Array<String>, exact:Bool):Bool {
		if (expected == null) {
			return true;
		}
		if (exact) {
			if (actual.length != expected.length) {
				return false;
			}
		} else if (actual.length < expected.length) {
			return false;
		}
		for (i in 0...expected.length) {
			var actualPart = actual[i];
			var expectedPart = expected[i];
			if (actualPart != expectedPart) {
				return false;
			}
		}
		return true;
	}

	private function isInHiddenPackage(pack:Array<String>):Bool {
		for (part in pack) {
			if (part.charAt(0) == "_") {
				return true;
			}
		}
		return false;
	}

	private function shouldSkipMacroType(type:Type, asReference:Bool):Bool {
		var baseType:BaseType = null;
		while (type != null) {
			switch (type) {
				case TInst(t, params):
					baseType = t.get();
					break;
				case TEnum(t, params):
					baseType = t.get();
					break;
				case TAbstract(t, params):
					var abstractType = t.get();
					if (abstractType.name == "Null" && abstractType.pack.length == 0) {
						return shouldSkipMacroType(params[0], asReference);
					}
					type = abstractType.type;
					switch (type) {
						case TAbstract(t, params):
							var result = baseTypeToQname(abstractType, params);
							var compareTo = baseTypeToQname(t.get(), params);
							if (result == compareTo) {
								// this avoids an infinite loop
								baseType = abstractType;
								break;
							}
						default:
					}
				case TType(t, params):
					type = t.get().type;
				case TDynamic(t):
					return false;
				case TAnonymous(a):
					return false;
				case TFun(args, ret):
					return false;
				case TLazy(f):
					type = f();
				case TMono(t):
					type = t.get();
				default:
					break;
			}
		}
		if (baseType == null) {
			return true;
		}
		return shouldSkipBaseType(baseType, asReference);
	}

	private function shouldSkipBaseType(baseType:BaseType, asReference:Bool):Bool {
		if (asReference && baseType.pack.length == 0 && ALWAYS_ALLOWED_REFERENCE_TYPES.indexOf(baseType.name) != -1) {
			return false;
		}
		if (baseType.isPrivate || (baseType.isExtern && !asReference) || isInHiddenPackage(baseType.pack)) {
			return true;
		}
		if (options != null) {
			if (options.includedPackages != null) {
				for (includedPackage in options.includedPackages) {
					if (isInPackage(includedPackage.split("."), baseType.pack, false)) {
						if (options.excludeSymbols != null) {
							var qname = baseTypeToQname(baseType, []);
							if (options.excludeSymbols.indexOf(qname) != -1) {
								return true;
							}
						}
						return false;
					}
				}
				if (!asReference) {
					return true;
				}
			} else if (options.excludeSymbols != null) {
				var qname = baseTypeToQname(baseType, []);
				if (options.excludeSymbols.indexOf(qname) != -1) {
					return true;
				}
			}
			if (asReference) {
				if (options.allowedPackageReferences != null) {
					for (allowedPackage in options.allowedPackageReferences) {
						if (isInPackage(allowedPackage.split("."), baseType.pack, false)) {
							return false;
						}
					}
					return true;
				}
			}
		}
		return false;
	}

	private function generateClass(classType:ClassType, params:Array<Type>):String {
		var result = new StringBuf();
		var packageName:String = null;
		if (classType.pack.length > 0) {
			packageName = classType.pack.join(".");
			result.add('package $packageName;\n');
		}
		result.add(generateClassTypeImports(classType));
		if (classType.doc != null && StringTools.trim(classType.doc).length > 0) {
			result.add('/**');
			result.add(classType.doc);
			result.add('**/\n');
		}
		result.add('class ${classType.name}');
		if (classType.superClass != null) {
			var superClassType = classType.superClass.t.get();
			if (!shouldSkipBaseType(superClassType, true)) {
				result.add(' extends ${baseTypeToQname(superClassType, classType.superClass.params)}');
			}
		}
		var interfaces = classType.interfaces;
		var foundFirstInterface = false;
		for (i in 0...interfaces.length) {
			var interfaceRef = interfaces[i];
			var implementedInterfaceType = interfaceRef.t.get();
			if (!shouldSkipBaseType(implementedInterfaceType, true)) {
				if (foundFirstInterface) {
					result.add(', ');
				} else {
					foundFirstInterface = true;
					result.add(' implements ');
				}
				result.add(baseTypeToQname(implementedInterfaceType, interfaceRef.params));
			}
		}
		result.add(' {\n');
		if (classType.constructor != null) {
			var constructor = classType.constructor.get();
			if (!shouldSkipField(constructor, classType)) {
				result.add(generateClassField(constructor, classType, false, null));
			}
		}
		for (classField in classType.statics.get()) {
			if (shouldSkipField(classField, classType)) {
				continue;
			}
			result.add(generateClassField(classField, classType, true, null));
		}
		for (classField in classType.fields.get()) {
			if (shouldSkipField(classField, classType)) {
				continue;
			}
			result.add(generateClassField(classField, classType, false, interfaces));
		}
		result.add('}\n');
		return result.toString();
	}

	private function generateClassField(classField:ClassField, classType:ClassType, isStatic:Bool,
			interfaces:Array<{t:Ref<ClassType>, params:Array<Type>}>):String {
		var result = new StringBuf();
		if (classField.doc != null && StringTools.trim(classField.doc).length > 0) {
			result.add("\t/**");
			result.add(classField.doc);
			result.add("**/\n");
		}
		result.add("\t");
		var superClassType:ClassType = null;
		var skippedSuperClass = false;
		if (classType != null && classType.superClass != null) {
			superClassType = classType.superClass.t.get();
			skippedSuperClass = shouldSkipBaseType(superClassType, true);
		}
		if (classField.meta.has(":noCompletion"))
		{
			result.add("@:noCompletion ");
		}
		switch (classField.kind) {
			case FMethod(k):
				if (!skippedSuperClass) {
					if (classType != null) {
						for (current in classType.overrides) {
							if (current.get().name == classField.name) {
								result.add('override ');
							}
						}
					}
				}
				if (classField.isPublic) {
					result.add('public ');
				}
				if (isStatic) {
					result.add('static ');
				}
				#if (haxe_ver >= 4.3)
				if (classField.isAbstract) {
					result.add('abstract ');
				}
				#end
				if (classField.isFinal) {
					result.add('final ');
				}
				if (classField.isExtern) {
					result.add('extern ');
				}
				result.add('function ');
				result.add(classField.name);
				switch (classField.type) {
					case TFun(args, ret):
						result.add('(');
						for (i in 0...args.length) {
							var arg = args[i];
							if (i > 0) {
								result.add(', ');
							}
							if (arg.opt) {
								result.add('?');
							}
							result.add(arg.name);
							result.add(':');
							if (shouldSkipMacroType(arg.t, true)) {
								result.add('Dynamic');
							} else {
								result.add(macroTypeToQname(arg.t));
							}
						}
						result.add(')');
						if (classField.name != "new") {
							result.add(':');
							var retQname = if (shouldSkipMacroType(ret, true)) {
								'Dynamic';
							} else {
								macroTypeToQname(ret);
							}
							result.add(retQname);
							switch (retQname) {
								case "Void":
									result.add(' {}');
								case "Float" | "Int" | "UInt":
									result.add(" { return 0; }");
								case "Bool":
									result.add(" { return false; }");
								default:
									result.add(" { return null; }");
							}
						} else {
							if (superClassType != null && !skippedSuperClass) {
								result.add(' {\n');
								result.add('\t\tsuper(');
								if (superClassType.constructor != null) {
									switch (superClassType.constructor.get().type) {
										case TFun(args, ret):
											for (i in 0...args.length) {
												if (i > 0) {
													result.add(', ');
												}
												result.add('undefined');
											}
										default:
									}
								}
								result.add(');\n');
								result.add('\t}');
							} else {
								result.add(' {}');
							}
						}
					default:
				}
			case FVar(read, write):
				if (classField.isPublic) {
					result.add('public ');
				}
				if (isStatic) {
					result.add('static ');
				}
				#if (haxe_ver >= 4.3)
				if (classField.isAbstract) {
					result.add('abstract ');
				}
				#end
				if (classField.isExtern) {
					result.add('extern ');
				}
				if (classField.isFinal) {
					result.add('final ');
				} else {
					result.add('var ');
				}
				result.add(classField.name);
				result.add('(');
				switch (read) {
					case AccCall:
						result.add('get');
					case AccNever:
						result.add('never');
					case AccNo:
						result.add('null');
					case AccNormal:
						result.add('default');
					default:
						result.add('default');
				}
				result.add(', ');
				switch (write) {
					case AccCall:
						result.add('set');
					case AccNever:
						result.add('never');
					case AccNo:
						result.add('null');
					case AccNormal:
						result.add('default');
					default:
						result.add('default');
				}
				result.add('):');
				if (shouldSkipMacroType(classField.type, true)) {
					result.add('Dynamic');
				} else {
					result.add(macroTypeToQname(classField.type));
				}
				result.add(";");
		}
		result.add('\n');
		return result.toString();
	}

	private function generateClassTypeImports(classType:ClassType):String {
		var qnames:Map<String, Bool> = [];
		if (classType.constructor != null) {
			var constructor = classType.constructor.get();
			if (!shouldSkipField(constructor, classType)) {
				switch (constructor.type) {
					case TFun(args, ret):
						for (arg in args) {
							var argType = arg.t;
							if (!canSkipMacroTypeImport(argType, classType.pack) && !shouldSkipMacroType(argType, true)) {
								var qname = macroTypeToQname(argType, false);
								qnames.set(qname, true);
							}
						}
					default:
				}
			}
		}
		if (classType.superClass != null) {
			var superClass = classType.superClass.t.get();
			if (!shouldSkipBaseType(superClass, true) && !canSkipBaseTypeImport(superClass, classType.pack)) {
				var qname = baseTypeToQname(superClass, []);
				qnames.set(qname, true);
			}
		}
		for (interfaceRef in classType.interfaces) {
			var interfaceType = interfaceRef.t.get();
			if (!shouldSkipBaseType(interfaceType, true) && !canSkipBaseTypeImport(interfaceType, classType.pack)) {
				var qname = baseTypeToQname(interfaceType, []);
				qnames.set(qname, true);
			}
		}
		for (classField in classType.statics.get()) {
			if (shouldSkipField(classField, classType)) {
				continue;
			}
			switch (classField.type) {
				case TFun(args, ret):
					for (arg in args) {
						var argType = arg.t;
						if (!canSkipMacroTypeImport(argType, classType.pack) && !shouldSkipMacroType(argType, true)) {
							var qname = macroTypeToQname(argType, false);
							qnames.set(qname, true);
						}
					}
					if (!canSkipMacroTypeImport(ret, classType.pack) && !shouldSkipMacroType(ret, true)) {
						var qname = macroTypeToQname(ret, false);
						qnames.set(qname, true);
					}
				default:
					if (!canSkipMacroTypeImport(classField.type, classType.pack) && !shouldSkipMacroType(classField.type, true)) {
						var qname = macroTypeToQname(classField.type, false);
						qnames.set(qname, true);
					}
			}
		}
		for (classField in classType.fields.get()) {
			if (shouldSkipField(classField, classType)) {
				continue;
			}
			switch (classField.type) {
				case TFun(args, ret):
					for (arg in args) {
						var argType = arg.t;
						if (!canSkipMacroTypeImport(argType, classType.pack) && !shouldSkipMacroType(argType, true)) {
							var qname = macroTypeToQname(argType, false);
							qnames.set(qname, true);
						}
					}
					if (!canSkipMacroTypeImport(ret, classType.pack) && !shouldSkipMacroType(ret, true)) {
						var qname = macroTypeToQname(ret, false);
						qnames.set(qname, true);
					}
				default:
					if (!canSkipMacroTypeImport(classField.type, classType.pack) && !shouldSkipMacroType(classField.type, true)) {
						var qname = macroTypeToQname(classField.type, false);
						qnames.set(qname, true);
					}
			}
		}

		var result = new StringBuf();
		for (qname in qnames.keys()) {
			result.add('import $qname;\n');
		}
		return result.toString();
	}

	private function generateInterface(interfaceType:ClassType, params:Array<Type>):String {
		var result = new StringBuf();
		if (interfaceType.pack.length > 0) {
			result.add('package ${interfaceType.pack.join(".")};\n');
		}
		result.add(generateClassTypeImports(interfaceType));
		if (interfaceType.doc != null && StringTools.trim(interfaceType.doc).length > 0) {
			result.add('/**');
			result.add(interfaceType.doc);
			result.add('**/\n');
		}
		result.add('interface ${interfaceType.name}');
		var interfaces = interfaceType.interfaces;
		var firstInterface = false;
		for (i in 0...interfaces.length) {
			var interfaceRef = interfaces[i];
			var implementedInterfaceType = interfaceRef.t.get();
			if (!shouldSkipBaseType(implementedInterfaceType, true)) {
				if (firstInterface) {
					result.add(', ');
				} else {
					firstInterface = true;
					result.add(' extends ');
				}
				result.add(baseTypeToQname(implementedInterfaceType, interfaceRef.params));
			}
		}
		result.add(' {\n');
		for (interfaceField in interfaceType.fields.get()) {
			if (shouldSkipField(interfaceField, interfaceType)) {
				continue;
			}
			result.add(generateInterfaceField(interfaceField));
		}
		result.add('}\n');
		return result.toString();
	}

	private function generateInterfaceField(interfaceField:ClassField):String {
		var result = new StringBuf();
		if (interfaceField.doc != null && StringTools.trim(interfaceField.doc).length > 0) {
			result.add("\t/**");
			result.add(interfaceField.doc);
			result.add("**/\n");
		}
		result.add("\t");
		switch (interfaceField.kind) {
			case FMethod(k):
				result.add('function ');
				result.add(interfaceField.name);
				switch (interfaceField.type) {
					case TFun(args, ret):
						result.add('(');
						for (i in 0...args.length) {
							var arg = args[i];
							if (i > 0) {
								result.add(', ');
							}
							if (arg.opt) {
								result.add('?');
							}
							result.add(arg.name);
							result.add(':');
							if (shouldSkipMacroType(arg.t, true)) {
								result.add('Dynamic');
							} else {
								result.add(macroTypeToQname(arg.t));
							}
						}
						result.add('):');
						if (shouldSkipMacroType(ret, true)) {
							result.add('Dynamic');
						} else {
							result.add(macroTypeToQname(ret));
						}
					default:
				}
			case FVar(read, write):
				// skip AccNormal fields because AS3 supports get/set only
				var hasGetter = read == AccCall;
				var hasSetter = write == AccCall;
				if (hasGetter) {
					result.add('function get ');
					result.add(interfaceField.name);
					result.add('():');
					if (shouldSkipMacroType(interfaceField.type, true)) {
						result.add('Dynamic');
					} else {
						result.add(macroTypeToQname(interfaceField.type));
					}
				}
				if (hasSetter) {
					if (hasGetter) {
						result.add(';\n\t');
					}
					result.add('function set ');
					result.add(interfaceField.name);
					result.add('(value:');
					if (shouldSkipMacroType(interfaceField.type, true)) {
						result.add('Dynamic');
					} else {
						result.add(macroTypeToQname(interfaceField.type));
					}
					result.add('):void');
				}
		}
		result.add(';\n');
		return result.toString();
	}

	private function generateEnum(enumType:EnumType, params:Array<Type>):String {
		var result = new StringBuf();
		if (enumType.pack.length > 0) {
			result.add('package ${enumType.pack.join(".")};\n');
		}
		if (enumType.doc != null && StringTools.trim(enumType.doc).length > 0) {
			result.add('/**');
			result.add(enumType.doc);
			result.add('**/\n');
		}
		result.add('enum ${enumType.name}');
		result.add(' {\n');
		for (enumField in enumType.constructs) {
			result.add(generateEnumField(enumField, enumType, params));
		}
		result.add('}\n');
		return result.toString();
	}

	private function generateEnumField(enumField:EnumField, enumType:EnumType, enumTypeParams:Array<Type>):String {
		var result = new StringBuf();
		if (enumField.doc != null && StringTools.trim(enumField.doc).length > 0) {
			result.add("\t/**");
			result.add(enumField.doc);
			result.add("**/\n");
		}
		result.add("\t");
		result.add('public static ');
		result.add('const ');
		result.add(enumField.name);
		result.add(':');
		result.add(baseTypeToQname(enumType, enumTypeParams));
		result.add(';');
		result.add('\n');
		return result.toString();
	}

	private function generateAbstractEnum(abstractType:AbstractType, params:Array<Type>):String {
		var result = new StringBuf();
		if (abstractType.pack.length > 0) {
			result.add('package ${abstractType.pack.join(".")};\n');
		}
		if (abstractType.doc != null && StringTools.trim(abstractType.doc).length > 0) {
			result.add('/**');
			result.add(abstractType.doc);
			result.add('**/\n');
		}
		result.add('#if haxe4 enum #else @:enum #end abstract ${abstractType.name}');
		result.add('(${macroTypeToQname(abstractType.type)})');
		for (currentFrom in abstractType.from) {
			if (currentFrom.field != null) {
				continue;
			}
			result.add(' from ${macroTypeToQname(currentFrom.t)}');
		}
		for (currentTo in abstractType.to) {
			if (currentTo.field != null) {
				continue;
			}
			result.add(' to ${macroTypeToQname(currentTo.t)}');
		}
		result.add(' {\n');
		if (abstractType.impl != null) {
			var classType = abstractType.impl.get();
			for (classField in classType.statics.get()) {
				if (shouldSkipField(classField, classType)) {
					continue;
				}
				result.add('\tpublic var ');
				result.add(classField.name);
				var expr = classField.expr();
				if (expr != null) {
					var currentExpr = expr;
					while (currentExpr != null) {
						switch (currentExpr.expr) {
							case TCast(e, m):
								currentExpr = e;
								continue;
							case TConst(c):
								switch (c) {
									case TInt(i):
										result.add(' = ');
										result.add(Std.string(i));
									case TFloat(s):
										result.add(' = ');
										result.add('"${s}"');
									case TString(s):
										result.add(' = ');
										result.add('"${s}"');
									case TBool(b):
										result.add(' = ');
										result.add(Std.string(b));
									case TNull:
										result.add(' = null');
									default:
								}
							default:
						}
						currentExpr = null;
					}
					result.add(';\n');
				}
			}
		}
		result.add('}\n');
		return result.toString();
	}

	private function shouldSkipField(classField:ClassField, classType:ClassType):Bool {
		if (classField.name != "new") {
			if (!classField.isPublic
				|| classField.isExtern) {
				return true;
			}
		}

		if (classType != null && classType.isInterface) {
			if (classField.kind.equals(FieldKind.FMethod(MethNormal)) && eregAccessor.match(classField.name)) {
				return true;
			}
		}
		return false;
	}

	private function canSkipMacroTypeImport(type:Type, currentPackage:Array<String>):Bool {
		var baseType:BaseType = null;
		while (type != null) {
			switch (type) {
				case TInst(t, params):
					var classType = t.get();
					switch (classType.kind) {
						case KTypeParameter(constraints):
							return true;
						default:
					}
					baseType = classType;
					break;
				case TEnum(t, params):
					baseType = t.get();
					break;
				case TAbstract(t, params):
					var abstractType = t.get();
					return canSkipAbstractTypeImport(abstractType, params, currentPackage);
				case TType(t, params):
					var typedefType = t.get();
					type = typedefType.type;
				case TDynamic(t):
					break;
				case TAnonymous(a):
					break;
				case TFun(args, ret):
					break;
				case TLazy(f):
					type = f();
				case TMono(t):
					type = t.get();
				default:
					break;
			}
		}
		if (baseType == null) {
			return true;
		}
		return canSkipBaseTypeImport(baseType, currentPackage);
	}

	private function canSkipAbstractTypeImport(abstractType:AbstractType, params:Array<Type>, currentPackage:Array<String>):Bool {
		var pack = abstractType.pack;
		if (abstractType.name == "Null" && pack.length == 0) {
			return canSkipMacroTypeImport(params[0], currentPackage);
		}
		var underlyingType = abstractType.type;
		switch (underlyingType) {
			case TAbstract(t, params):
				var result = baseTypeToQname(abstractType, params);
				var compareTo = baseTypeToQname(t.get(), params);
				if (result == compareTo) {
					// this avoids an infinite loop
					return canSkipBaseTypeImport(abstractType, currentPackage);
				}
			default:
		}
		return canSkipMacroTypeImport(underlyingType, currentPackage);
	}

	private function canSkipBaseTypeImport(baseType:BaseType, currentPackage:Array<String>):Bool {
		if (baseType == null) {
			return true;
		}
		var qname = baseTypeToQname(baseType, []);
		if (qname.indexOf(".") == -1) {
			return true;
		}
		if (isInPackage(currentPackage, baseType.pack, true)) {
			return true;
		}
		return false;
	}

	private function macroTypeToQname(type:Type, includeParams:Bool = true):String {
		while (type != null) {
			switch (type) {
				case TInst(t, params):
					var classType = t.get();
					switch (classType.kind) {
						case KTypeParameter(constraints):
							return "*";
						default:
					}
					return baseTypeToQname(classType, includeParams ? params : []);
				case TEnum(t, params):
					return baseTypeToQname(t.get(), includeParams ? params : []);
				case TAbstract(t, params):
					return abstractTypeToQname(t.get(), params);
				case TType(t, params):
					var defType = t.get();
					if (options != null && options.renameSymbols != null) {
						var buffer = new StringBuf();
						if (defType.pack.length > 0) {
							buffer.add(defType.pack.join("."));
							buffer.add(".");
						}
						buffer.add(defType.name);
						var qname = buffer.toString();
						var renameSymbols = options.renameSymbols;
						var i = 0;
						while (i < renameSymbols.length) {
							var originalName = renameSymbols[i];
							i++;
							var newName = renameSymbols[i];
							i++;
							if (originalName == qname) {
								return newName;
							}
						}
					}
					type = t.get().type;
				case TDynamic(t):
					return "*";
				case TAnonymous(a):
					return "Object";
				case TFun(args, ret):
					return "Function";
				case TLazy(f):
					type = f();
				case TMono(t):
					type = t.get();
				default:
					return "*";
			}
		}
		return "*";
	}

	private function baseTypeToQname(baseType:BaseType, params:Array<Type>):String {
		if (baseType == null) {
			return "*";
		}
		var buffer = new StringBuf();
		if (baseType.pack.length > 0) {
			buffer.add(baseType.pack.join("."));
			buffer.add(".");
		}
		buffer.add(baseType.name);
		var qname = buffer.toString();
		if (options != null && options.renameSymbols != null) {
			var renameSymbols = options.renameSymbols;
			var i = 0;
			while (i < renameSymbols.length) {
				var originalName = renameSymbols[i];
				i++;
				var newName = renameSymbols[i];
				i++;
				if (originalName == qname) {
					return newName;
				}
			}
		}

		// ignore type params in AS3

		return qname;
	}

	private function baseTypeToUnqualifiedNname(baseType:BaseType, params:Array<Type>):String {
		if (baseType == null) {
			return "*";
		}
		var buffer = new StringBuf();
		if (baseType.pack.length > 0) {
			buffer.add(baseType.pack.join("."));
			buffer.add(".");
		}
		buffer.add(baseType.name);
		var qname = buffer.toString();
		if (options != null && options.renameSymbols != null) {
			var renameSymbols = options.renameSymbols;
			var i = 0;
			while (i < renameSymbols.length) {
				var originalName = renameSymbols[i];
				i++;
				var newName = renameSymbols[i];
				i++;
				if (originalName == qname) {
					return newName;
				}
			}
		}
		// ignore type params in AS3
		return qname;
	}

	private function abstractTypeToQname(abstractType:AbstractType, params:Array<Type>):String {
		var pack = abstractType.pack;
		var underlyingType = abstractType.type;
		switch (underlyingType) {
			case TAbstract(t, params):
				var result = baseTypeToQname(abstractType, params);
				var compareTo = baseTypeToQname(t.get(), params);
				if (result == compareTo) {
					// this avoids an infinite loop
					return result;
				}
			default:
		}
		return macroTypeToQname(underlyingType);
	}

	private function writeGenerated(outputDirPath:String, baseType:BaseType, generated:String):Void {
		var outputFilePath = getFileOutputPath(outputDirPath, baseType);
		FileSystem.createDirectory(Path.directory(outputFilePath));
		var fileOutput = File.write(outputFilePath);
		fileOutput.writeString(generated);
		fileOutput.close();
	}

	private function getFileOutputPath(dirPath:String, baseType:BaseType):String {
		var qname = baseTypeToQname(baseType, []);
		var relativePath = qname.split(".").join("/") + ".hx";
		return Path.join([dirPath, relativePath]);
	}
}

typedef HaxeGeneratorOptions = {
	/**
		Externs will be generated for symbols in the specified packages only,
		and no externs will be generated for symbols in other packages.

		Types from other packages may still be referenced by fields or method
		signatures. Use `allowedPackageReferences` to restrict those too.
	**/
	?includedPackages:Array<String>,

	/**
		When `includedPackages` is not empty, `allowedPackageReferences` may
		be used to allow types from other packages to be used for field types,
		method parameter types, and method return types. Otherwise, the types
		will be replaced with Haxe's `Dynamic` type.
			
		All package references are allowed by default. If in doubt, pass an
		empty array to restrict all types that don't appear in
		`includedPackages`.
	**/
	?allowedPackageReferences:Array<String>,

	/**
		Gives specific symbols new names. Alternates between the original symbol
		name and its new name.
	**/
	?renameSymbols:Array<String>,

	/**
		Optionally exclude specific symbols.
	**/
	?excludeSymbols:Array<String>,

	/**
		The target directory where externs files will be generated.
	**/
	?outputPath:String
}
