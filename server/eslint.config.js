import eslint from "@eslint/js";
import tseslint from "typescript-eslint";
import prettier from "eslint-config-prettier";

const FILE_SIZE_LIMIT = 500;

function isConsoleLogCall(node) {
  const callee =
    node.callee.type === "ChainExpression" ? node.callee.expression : node.callee;

  if (callee.type !== "MemberExpression" || callee.computed) {
    return false;
  }

  return (
    callee.object.type === "Identifier" &&
    callee.object.name === "console" &&
    callee.property.type === "Identifier" &&
    callee.property.name === "log"
  );
}

function hasTemplateLiteralOrStringConcatenation(node) {
  if (node.type === "TemplateLiteral") {
    return true;
  }

  if (node.type === "BinaryExpression" && node.operator === "+") {
    return true;
  }

  return false;
}

const localPlugin = {
  rules: {
    "file-size-limit": {
      meta: {
        type: "suggestion",
        docs: {
          description: "Warn when source files exceed 500 lines",
        },
        schema: [],
        messages: {
          fileTooLarge:
            "Large files are hard for agents to reason about. Consider splitting — see ARCHITECTURE.md for layer boundaries. ({{lineCount}} lines)",
        },
      },
      create(context) {
        return {
          Program(node) {
            const lineCount = context.sourceCode.lines.length;
            if (lineCount > FILE_SIZE_LIMIT) {
              context.report({
                node,
                messageId: "fileTooLarge",
                data: { lineCount: String(lineCount) },
              });
            }
          },
        };
      },
    },
    "no-any-in-types": {
      meta: {
        type: "problem",
        docs: {
          description: "Disallow `any` in protocol contract types",
        },
        schema: [],
        messages: {
          noAny:
            "types.ts is the protocol contract — use explicit types. See ARCHITECTURE.md#protocol-boundary",
        },
      },
      create(context) {
        return {
          TSAnyKeyword(node) {
            context.report({
              node,
              messageId: "noAny",
            });
          },
        };
      },
    },
    "structured-log-format": {
      meta: {
        type: "suggestion",
        docs: {
          description:
            "Warn when console.log uses template strings or concatenation",
        },
        schema: [],
        messages: {
          useStructuredLogs:
            "Use structured logging. See docs/golden-principles.md#server-conventions",
        },
      },
      create(context) {
        return {
          CallExpression(node) {
            if (!isConsoleLogCall(node)) {
              return;
            }

            if (
              node.arguments.some(
                (argument) =>
                  argument.type !== "SpreadElement" &&
                  hasTemplateLiteralOrStringConcatenation(argument),
              )
            ) {
              context.report({
                node,
                messageId: "useStructuredLogs",
              });
            }
          },
        };
      },
    },
  },
};

export default tseslint.config(
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  prettier,
  {
    ignores: ["dist/", "node_modules/", "extensions/"],
  },
  {
    files: ["src/**/*.ts"],
    plugins: {
      local: localPlugin,
    },
    rules: {
      // Dead code / unused
      "@typescript-eslint/no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          varsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
        },
      ],

      // Prevent duplicate/confusing patterns
      // no-duplicate-imports off: conflicts with consistent-type-imports (separate type imports)
      "no-duplicate-imports": "off",
      "no-self-compare": "error",
      "no-template-curly-in-string": "warn",

      // Code quality
      // Server app — console.log is the logging mechanism
      "no-console": "off",
      "no-empty": ["error", { allowEmptyCatch: true }],
      eqeqeq: ["error", "always"],
      "no-var": "error",
      "prefer-const": "error",
      "no-throw-literal": "error",
      "no-return-await": "error",
      "local/file-size-limit": "warn",
      "local/structured-log-format": "warn",

      // TypeScript-specific
      "@typescript-eslint/no-explicit-any": "warn",
      "@typescript-eslint/explicit-function-return-type": [
        "warn",
        {
          allowExpressions: true,
          allowTypedFunctionExpressions: true,
          allowHigherOrderFunctions: true,
        },
      ],
      "@typescript-eslint/no-non-null-assertion": "warn",
      "@typescript-eslint/consistent-type-imports": [
        "error",
        { prefer: "type-imports" },
      ],
    },
  },
  {
    files: ["src/types.ts"],
    plugins: {
      local: localPlugin,
    },
    rules: {
      "local/no-any-in-types": "error",
    },
  },
);
