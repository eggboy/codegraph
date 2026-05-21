/**
 * VS Code GitHub Copilot target.
 *
 * Writes:
 *   - MCP server entry to `./.vscode/mcp.json` (workspace scope —
 *     the file VS Code Copilot actually reads for per-project MCP).
 *   - Instructions to `./.github/copilot-instructions.md` (the standard
 *     Copilot convention; read by GH.com Copilot Chat, Copilot Code
 *     Review, VS Code Copilot, JetBrains, and the cloud agent).
 *
 * ## Config shape
 *
 * VS Code's `mcp.json` uses a top-level `servers` key — NOT
 * `mcpServers` like Claude/Cursor. It's JSONC, so we go through
 * `jsonc-parser` (the same path opencode uses) so user comments and
 * trailing commas survive idempotent re-runs.
 *
 *   {
 *     "servers": {
 *       "codegraph": {
 *         "type": "stdio",
 *         "command": "codegraph",
 *         "args": ["serve", "--mcp", "--path", "${workspaceFolder}"]
 *       }
 *     }
 *   }
 *
 * ## Why we inject `--path "${workspaceFolder}"`
 *
 * Same defensive choice Cursor makes: VS Code's MCP launcher does not
 * reliably pass `rootUri` / `workspaceFolders` to stdio MCP servers,
 * so `process.cwd()` may land outside the workspace. `${workspaceFolder}`
 * is a documented VS Code variable substitution, expanded before the
 * server is spawned. With this in place the server always finds
 * `.codegraph/` regardless of launch cwd.
 *
 * ## Global scope
 *
 * VS Code's user-profile `mcp.json` lives at a profile-dependent path
 * (Stable vs Insiders vs VSCodium, possibly per profile) we can't
 * reliably resolve from a filesystem check. `supportsLocation('global')`
 * therefore returns false; the orchestrator skips a global install
 * with a clear message. Users who want global config get the snippet
 * via `codegraph install --print-config copilot-vscode` and add it
 * through VS Code's `MCP: Open User Configuration` command or
 * `code --add-mcp`.
 *
 * ## Permissions
 *
 * VS Code Copilot has no Claude-style auto-allow list — trust is
 * UI-managed per workspace. `autoAllow` is a no-op.
 */

import * as fs from 'fs';
import * as path from 'path';
import { parse as parseJsonc, modify, applyEdits } from 'jsonc-parser';
import {
  AgentTarget,
  DetectionResult,
  InstallOptions,
  Location,
  WriteResult,
} from './types';
import {
  atomicWriteFileSync,
  getMcpServerConfig,
  jsonDeepEqual,
  removeMarkedSection,
  replaceOrAppendMarkedSection,
} from './shared';
import {
  CODEGRAPH_SECTION_END,
  CODEGRAPH_SECTION_START,
  INSTRUCTIONS_TEMPLATE,
} from '../instructions-template';

function vscodeDir(): string {
  return path.join(process.cwd(), '.vscode');
}
function mcpJsonPath(): string {
  return path.join(vscodeDir(), 'mcp.json');
}
function instructionsPath(): string {
  return path.join(process.cwd(), '.github', 'copilot-instructions.md');
}

const FORMATTING = { tabSize: 2, insertSpaces: true, eol: '\n' };

function readConfigText(file: string): string {
  if (!fs.existsSync(file)) return '';
  return fs.readFileSync(file, 'utf-8');
}

function parseConfig(text: string): Record<string, any> {
  if (!text.trim()) return {};
  const errors: any[] = [];
  const result = parseJsonc(text, errors, { allowTrailingComma: true });
  if (result == null || typeof result !== 'object' || Array.isArray(result)) {
    return {};
  }
  return result as Record<string, any>;
}

/**
 * Build the codegraph server entry for VS Code Copilot. Inherits the
 * shared `{type, command, args}` shape and injects `--path` so the
 * spawned MCP server resolves the workspace correctly regardless of
 * VS Code's launch cwd.
 */
function buildVscodeServerEntry(): { type: string; command: string; args: string[] } {
  const base = getMcpServerConfig();
  return { ...base, args: [...base.args, '--path', '${workspaceFolder}'] };
}

class CopilotVscodeTarget implements AgentTarget {
  readonly id = 'copilot-vscode' as const;
  readonly displayName = 'GitHub Copilot (VS Code)';
  readonly docsUrl = 'https://docs.github.com/en/copilot/customizing-copilot/extending-copilot-chat-with-mcp';

  supportsLocation(loc: Location): boolean {
    // Local only. Global VS Code user-profile mcp.json lives at a
    // profile-dependent path we can't safely write; `printConfig`
    // remains available for manual setup.
    return loc === 'local';
  }

  detect(loc: Location): DetectionResult {
    if (loc !== 'local') {
      return { installed: false, alreadyConfigured: false };
    }
    const file = mcpJsonPath();
    const config = parseConfig(readConfigText(file));
    const alreadyConfigured = !!config.servers?.codegraph;
    // "Installed" heuristic: a project-local `.vscode/mcp.json` is a
    // strong signal — far less noisy than just `.vscode/`, which
    // exists in many repos for unrelated settings.
    const installed = fs.existsSync(file);
    return { installed, alreadyConfigured, configPath: file };
  }

  install(loc: Location, _opts: InstallOptions): WriteResult {
    if (loc !== 'local') {
      return {
        files: [],
        notes: [
          'VS Code Copilot has no auto-resolvable global MCP path — use `codegraph install --print-config copilot-vscode` and paste via `MCP: Open User Configuration` (or `code --add-mcp`).',
        ],
      };
    }
    const files: WriteResult['files'] = [];
    files.push(writeMcpEntry());
    files.push(writeInstructionsEntry());
    return {
      files,
      notes: ['Reload VS Code (or run `MCP: Reset Cached Tools`) for changes to take effect.'],
    };
  }

  uninstall(loc: Location): WriteResult {
    if (loc !== 'local') return { files: [] };
    const files: WriteResult['files'] = [];

    const file = mcpJsonPath();
    if (!fs.existsSync(file)) {
      files.push({ path: file, action: 'not-found' });
    } else {
      const text = readConfigText(file);
      const config = parseConfig(text);
      if (!config.servers?.codegraph) {
        files.push({ path: file, action: 'not-found' });
      } else {
        let edits = modify(text, ['servers', 'codegraph'], undefined, {
          formattingOptions: FORMATTING,
        });
        let updated = applyEdits(text, edits);

        // Drop the `servers` wrapper if it's now empty.
        const afterParsed = parseConfig(updated);
        if (afterParsed.servers && typeof afterParsed.servers === 'object' &&
            Object.keys(afterParsed.servers).length === 0) {
          edits = modify(updated, ['servers'], undefined, { formattingOptions: FORMATTING });
          updated = applyEdits(updated, edits);
        }

        // If the file is now an empty `{}`, drop it entirely — matches
        // the marker-based instruction uninstall semantics.
        const finalParsed = parseConfig(updated);
        if (Object.keys(finalParsed).length === 0) {
          try { fs.unlinkSync(file); } catch { /* ignore */ }
        } else {
          atomicWriteFileSync(file, updated);
        }
        files.push({ path: file, action: 'removed' });
      }
    }

    const instr = instructionsPath();
    const instrAction = removeMarkedSection(instr, CODEGRAPH_SECTION_START, CODEGRAPH_SECTION_END);
    files.push({ path: instr, action: instrAction });

    return { files };
  }

  printConfig(loc: Location): string {
    if (loc !== 'local') {
      // The snippet itself is identical — Copilot reads the same
      // shape from workspace and user-profile mcp.json — but tell
      // the user where to paste it.
      const snippet = JSON.stringify({ servers: { codegraph: buildVscodeServerEntry() } }, null, 2);
      return `# Add to VS Code user-profile mcp.json (open via Command Palette → "MCP: Open User Configuration",\n# or run \`code --add-mcp\` with this entry):\n\n${snippet}\n`;
    }
    const snippet = JSON.stringify({ servers: { codegraph: buildVscodeServerEntry() } }, null, 2);
    return `# Add to ${mcpJsonPath()}\n\n${snippet}\n`;
  }

  describePaths(loc: Location): string[] {
    if (loc !== 'local') return [];
    return [mcpJsonPath(), instructionsPath()];
  }
}

function writeMcpEntry(): WriteResult['files'][number] {
  const file = mcpJsonPath();
  const dir = path.dirname(file);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  const existed = fs.existsSync(file);
  let text = readConfigText(file);
  if (!text.trim()) {
    text = '{}\n';
  }

  const config = parseConfig(text);
  const before = config.servers?.codegraph;
  const after = buildVscodeServerEntry();

  if (jsonDeepEqual(before, after)) {
    return { path: file, action: 'unchanged' };
  }

  const edits = modify(text, ['servers', 'codegraph'], after, {
    formattingOptions: FORMATTING,
  });
  const updated = applyEdits(text, edits);
  atomicWriteFileSync(file, updated);

  return { path: file, action: existed ? 'updated' : 'created' };
}

function writeInstructionsEntry(): WriteResult['files'][number] {
  const file = instructionsPath();
  const dir = path.dirname(file);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  const action = replaceOrAppendMarkedSection(
    file,
    INSTRUCTIONS_TEMPLATE,
    CODEGRAPH_SECTION_START,
    CODEGRAPH_SECTION_END,
  );
  const mapped: 'created' | 'updated' | 'unchanged' =
    action === 'created' ? 'created'
      : action === 'unchanged' ? 'unchanged'
        : 'updated';
  return { path: file, action: mapped };
}

export const copilotVscodeTarget: AgentTarget = new CopilotVscodeTarget();
