import {z} from 'zod';

export const protocolVersion = 1;
// Additive features are negotiated separately so existing v1 clients keep working.
export const daemonFeatures = ['agent.supervision','project.remove','github','workspace.delete','workspace.delete.discard','workspace.delete.stop-terminals','terminal.multiple','provider.usage','terminal.activity','terminal.notifications','github.checks','workspace.remote-default','project.worktree-startup','project.folderless','workspace.from-pr'] as const;
const id = z.uuid();
const githubTarget = {workspaceId:id, repository:z.string().regex(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/), branch:z.string().min(1).max(255), expectedHead:z.string().regex(/^[a-f0-9]{40,64}$/)};
export const Provider = z.enum(['codex', 'claude', 'shell']);
export type Provider = z.infer<typeof Provider>;
export interface Project {id:string; name:string; path:string; isGit?:boolean; folderless?:boolean; worktreeStartup?:Provider[]; createdAt:string}
// Immutable workspace provenance. localBranch/sourceHead describe creation, not live Git state.
export interface PullRequestSource {repository:string; number:number; localBranch:string; sourceHead:string}
export interface Workspace {id:string; projectId:string; name:string; path:string; branch:string; kind:'root'|'worktree'|'folder'|'scratch'; createdAt:string; pullRequestSource?:PullRequestSource}
export type AgentActivity = 'working'|'waiting'|'idle'|'unknown';
export interface TerminalRecord {id:string;agentId?:string; workspaceId:string; provider:Provider; status:'running'|'exited'|'interrupted'; activity?:AgentActivity; createdAt:string; exitCode?:number; cols:number; rows:number}
export interface AgentNotification {id:string;terminalId:string;workspaceId:string;provider:Provider;kind:'waiting'|'completed';createdAt:string}
export const Command = z.discriminatedUnion('type', [
  z.object({type:z.literal('project.remove'), projectId:id}),
  z.object({type:z.literal('project.create'), name:z.string().trim().min(1).max(80)}),
  z.object({type:z.literal('project.attach'), projectId:id, path:z.string().min(1).max(4096)}),
  z.object({type:z.literal('project.add'), path:z.string().min(1).max(4096)}),
  z.object({type:z.literal('project.set-worktree-startup'), projectId:id, providers:z.array(Provider).max(3).refine(values=>new Set(values).size===values.length)}),
  z.object({type:z.literal('workspace.create'), projectId:id, name:z.string().trim().min(1).max(80).optional(), baseRef:z.string().min(1).max(200).optional(), pullRequest:z.string().trim().min(1).max(500).optional(),skipStartup:z.boolean().default(false)}),
  z.object({type:z.literal('workspace.sync-default'), workspaceId:id}),
  z.object({type:z.literal('workspace.delete'), workspaceId:id, discardChanges:z.boolean().default(false), stopTerminals:z.boolean().default(false)}),
  z.object({type:z.literal('terminal.open'), workspaceId:id, provider:Provider, resume:z.boolean().default(false),prompt:z.string().min(1).max(65536).optional(),resumeId:id.optional(),parentTaskId:id.optional()}),
  z.object({type:z.literal('agent.watch'),agentId:id,taskIds:z.array(id).max(32).refine(ids=>new Set(ids).size===ids.length)}),
  z.object({type:z.literal('agent.send'),agentId:id,text:z.string().trim().min(1).max(65536),mode:z.enum(['queue','steer']).default('queue'),expectedTurnId:id.optional()}),
  z.object({type:z.literal('agent.interrupt'),agentId:id,expectedTurnId:id}),
  z.object({type:z.literal('agent.respond'),agentId:id,requestId:z.union([z.string().max(256),z.number().int()]),result:z.record(z.string(),z.unknown())}),
  z.object({type:z.literal('terminal.input'), terminalId:id, clientId:id, data:z.string().max(65536)}),
  z.object({type:z.literal('terminal.resize'), terminalId:id, clientId:id, cols:z.number().int().min(20).max(400), rows:z.number().int().min(5).max(200)}),
  z.object({type:z.literal('terminal.stop'), terminalId:id}),
  z.object({type:z.literal('file.save'), workspaceId:id, path:z.string().min(1).max(4096), content:z.string().max(1048576), expectedHash:z.string().length(64)}),
  z.object({type:z.literal('github.push'), ...githubTarget}),
  z.object({type:z.literal('github.create'), ...githubTarget, title:z.string().trim().min(1).max(256), body:z.string().max(65536), base:z.string().min(1).max(255), draft:z.boolean()}),
  z.object({type:z.literal('github.merge'), ...githubTarget, number:z.number().int().positive(), method:z.enum(['merge','squash','rebase']), expectedPRHead:z.string().regex(/^[a-f0-9]{40}$/)}),
]);
export type Command = z.infer<typeof Command>;
export const Envelope = z.object({operationId:id, command:Command});
export class Fault extends Error {constructor(public code:string, message:string, public status=400){super(message);}}
export function requireValue<T>(value:T|null|undefined, code:string, message:string):T {if(value===null||value===undefined)throw new Fault(code,message,404);return value;}
