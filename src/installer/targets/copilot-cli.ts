/**
 * GitHub Copilot CLI target.
 *
 * Writes:
 *   - MCP server entry to `~/.copilot/mcp-config.json` (or
 *     `$COPILOT_HOME/mcp-config.json` if set).
 *   - Instructions to `~/.copilot/copilot-instructions.md`.
 *
 * ## Config shape
 *
 *   {
 *     "mcpServers": {
 *       "codegraph": {
 *         "type": "stdio",
 *         "command": "codegraph",
 *         "args": ["serve", "--mcp"],
 *         "tools": ["codegraph_search", ...]
 *       }
 *     }
 *   }
 *
 * Top-level `mcpServers` (NOT `servers` like VS Code). The `tools`
 * array is an explicit allowlist — without it the CLI assumes all
 * tools and the cloud agent docs strongly recommend pinning the list
 * to read-only tools the agent can use without per-call approval.
 * Listing all 9 codegraph tools is appropriate because they are all
 * read-only structural queries.
 *
 * ## Global only
 *
 * Copilot CLI has no documented project-local MCP config path that
 * doesn't collide with Claude Code's `.mcp.json` (which this repo
 * already owns). `supportsLocation('local')` returns false — same
 * pattern Codex uses. Project-local instructions are handled by the
 * `copilot-vscode` target's `.github/copilot-instructions.md` file,
 * which the CLI also reads when run from a project root.
 *
 * ## Permissions
 *
 * The `tools` allowlist IS the permissions model for Copilot CLI.
 * `autoAllow` doesn't gate it — the list is always written, because
 * a missing `tools` field would surface every tool with an approval
 * prompt the user must answer per-call.
 */

import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import {
  AgentTarget,
  DetectionResult,
  InstallOptions,
  Location,
  WriteResult,
} from './types';
import {
  getMcpServerConfig,
  jsonDeepEqual,
  readJsonFile,
  removeMarkedSection,
  replaceOrAppendMarkedSection,
  writeJsonFile,
} from './shared';
import {
  CODEGRAPH_SECTION_END,
  CODEGRAPH_SECTION_START,
  INSTRUCTIONS_TEMPLATE,
} from '../instructions-template';

/**
 * The complete list of codegraph MCP tools. Mirrors the permissions
 * list in `shared.ts::getCodeGraphPermissions` (Claude format) plus
 * the tools that don't appear there because they're not yet on
 * Claude's permission surface (`codegraph_explore`, `codegraph_files`).
 *
 * Keep this in sync with `src/mcp/tools.ts`.
 */
function getCopilotCliToolAllowlist(): string[] {
  return [
    'codegraph_search',
    'codegraph_context',
    'codegraph_callers',
    'codegraph_callees',
    'codegraph_impact',
    'codegraph_node',
    'codegraph_explore',
    'codegraph_files',
    'codegraph_status',
  ];
}

function configDir(): string {
  const fromEnv = process.env.COPILOT_HOME;
  if (fromEnv && fromEnv.trim().length > 0) return fromEnv;
  return path.join(os.homedir(), '.copilot');
}
function mcpJsonPath(): string {
  return path.join(configDir(), 'mcp-config.json');
}
function instructionsPath(): string {
  return path.join(configDir(), 'copilot-instructions.md');
}

function buildCliServerEntry(): {
  type: string;
  command: string;
  args: string[];
  tools: string[];
} {
  const base = getMcpServerConfig();
  return { ...base, tools: getCopilotCliToolAllowlist() };
}

class CopilotCliTarget implements AgentTarget {
  readonly id = 'copilot-cli' as const;
  readonly displayName = 'GitHub Copilot CLI';
  readonly docsUrl = 'https://docs.github.com/en/copilot/github-copilot-in-the-cli';

  supportsLocation(loc: Location): boolean {
    return loc === 'global';
  }

  detect(loc: Location): DetectionResult {
    if (loc !== 'global') {
      return { installed: false, alreadyConfigured: false };
    }
    const file = mcpJsonPath();
    const config = readJsonFile(file);
    const alreadyConfigured = !!config.mcpServers?.codegraph;
    const installed = fs.existsSync(configDir());
    return { installed, alreadyConfigured, configPath: file };
  }

  install(loc: Location, _opts: InstallOptions): WriteResult {
    if (loc !== 'global') {
      return {
        files: [],
        notes: ['Copilot CLI has no project-local config — re-run with --location=global to install.'],
      };
    }
    const files: WriteResult['files'] = [];
    files.push(writeMcpEntry());
    files.push(writeInstructionsEntry());
    return { files };
  }

  uninstall(loc: Location): WriteResult {
    if (loc !== 'global') return { files: [] };
    const files: WriteResult['files'] = [];

    const file = mcpJsonPath();
    const config = readJsonFile(file);
    if (config.mcpServers?.codegraph) {
      delete config.mcpServers.codegraph;
      if (Object.keys(config.mcpServers).length === 0) {
        delete config.mcpServers;
      }
      // If removing codegraph leaves the file completely empty, drop
      // it entirely. Matches the marker-based instruction uninstall.
      if (Object.keys(config).length === 0) {
        try { fs.unlinkSync(file); } catch { /* ignore */ }
      } else {
        writeJsonFile(file, config);
      }
      files.push({ path: file, action: 'removed' });
    } else {
      files.push({ path: file, action: 'not-found' });
    }

    const instr = instructionsPath();
    const instrAction = removeMarkedSection(instr, CODEGRAPH_SECTION_START, CODEGRAPH_SECTION_END);
    files.push({ path: instr, action: instrAction });

    return { files };
  }

  printConfig(loc: Location): string {
    if (loc !== 'global') {
      return '# Copilot CLI has no project-local config — use --location=global.\n';
    }
    const snippet = JSON.stringify({ mcpServers: { codegraph: buildCliServerEntry() } }, null, 2);
    return `# Add to ${mcpJsonPath()}\n\n${snippet}\n`;
  }

  describePaths(loc: Location): string[] {
    if (loc !== 'global') return [];
    return [mcpJsonPath(), instructionsPath()];
  }
}

function writeMcpEntry(): WriteResult['files'][number] {
  const file = mcpJsonPath();
  const dir = path.dirname(file);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  const existed = fs.existsSync(file);
  const existing = readJsonFile(file);
  const before = existing.mcpServers?.codegraph;
  const after = buildCliServerEntry();

  if (jsonDeepEqual(before, after)) {
    return { path: file, action: 'unchanged' };
  }

  if (!existing.mcpServers) existing.mcpServers = {};
  existing.mcpServers.codegraph = after;
  writeJsonFile(file, existing);

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

export const copilotCliTarget: AgentTarget = new CopilotCliTarget();
