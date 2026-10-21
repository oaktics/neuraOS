import {ArtifactName,providerArtifactNamePattern} from './artifact-name.ts';
import { z } from 'zod';

export const Id = z.string().uuid();
export const Classification = z.enum(['standard', 'restricted', 'local-only']);
export const Provider = z.enum(['codex', 'claude', 'fixture']);
export const TaskStatus = z.enum(['draft','ready','queued','running','verifying','succeeded','needs_revision','waiting_approval','waiting_input','paused','blocked','failed','canceled']);
export type TaskStatus = z.infer<typeof TaskStatus>;
export const Criterion = z.object({ id: Id, description: z.string().min(1).max(2000), kind: z.enum(['artifact','contains','json','human','node-test']), value: z.string().max(10000).default(''), required: z.boolean().default(true) });
export type Criterion = z.infer<typeof Criterion>;
export const Budget = z.object({ maxSeconds: z.number().int().min(10).max(86400).default(600), maxCalls: z.number().int().min(1).max(100).default(4), maxTokens: z.number().int().min(100).max(2000000).default(50000), maxUsd: z.number().positive().max(1000).nullable().default(null) });
export type Budget = z.infer<typeof Budget>;
export const Source = z.object({id:Id,title:z.string().min(1).max(200),content:z.string().max(500000),origin:z.enum(['user','external']),classification:Classification,url:z.string().url().nullable().default(null),retrievedAt:z.string().datetime()});
export type Source=z.infer<typeof Source>;
export const TaskInput = z.object({ title: z.string().trim().min(1).max(200), objective: z.string().trim().min(1).max(30000), constraints: z.string().max(10000).default(''), sources:z.array(Source).max(20).default([]), projectId: Id.nullable().default(null), provider: Provider.default('codex'), model: z.string().max(120).default(''), classification: Classification.default('standard'), allowedProviders: z.array(Provider).default(['codex','claude']), criteria: z.array(Criterion).min(1).max(50), budget: Budget.default({maxSeconds:600,maxCalls:4,maxTokens:50000,maxUsd:null}), cloudRequired: z.boolean().default(false), dueAt: z.string().datetime().nullable().default(null) });
export type TaskInput = z.infer<typeof TaskInput>;
export interface Plan { version: number; requirementsVersion: number; objective: string; constraints: string; criteria: Criterion[]; steps: { id: string; title: string; output: string; completion: string; dependencies: string[]; retry: 'safe' | 'reconcile' | 'never' }[]; createdAt: string }
export interface Artifact { id: string; name: string; content: string; hash: string; mediaType: string; size: number; runId: string; createdAt: string; cloudKey: string | null; cloudVerifiedAt: string | null }
export interface Verification { id: string; criterionId: string; runId: string; passed: boolean; evidence: string; environment: 'local' | 'container' | 'user' | 'cloud'; verifier: string; createdAt: string }
export interface Run { reservedTokens?:number; reservedCalls?:number; usageEstimated?:boolean; id: string; planVersion: number; provider: z.infer<typeof Provider>; model: string; status: TaskStatus; reason: string; runnerId: string; fencingToken: number; leaseUntil: string; startedAt: string; endedAt: string | null; sessionId: string | null; adapterVersion: string; calls: number; tokens: number; costUsd: number | null; sequence: number; memoryVersions: { id: string; version: number; reason: string }[]; attempts: { stepId: string; attemptNo: number; state: 'running' | 'succeeded' | 'failed'; evidence: string }[] }
export interface Event { id: string; runId: string; sequence: number; kind: string; message: string; createdAt: string; historical: boolean }
export interface Action { id: string; runId: string; planVersion: number; kind: 'github.issue.create'; connectorId: string; target: string; payload: {title: string; body: string}; hash: string; idempotencyKey: string; status: 'proposed' | 'dispatching' | 'unknown' | 'succeeded' | 'denied'; externalId: string | null; resultUrl: string | null; createdAt: string }
export interface Approval { id: string; actionId: string; hash: string; planVersion: number; expiresAt: string; decision: 'pending' | 'approved' | 'denied'; actor: string | null; decidedAt: string | null }
export interface WorkAssignment {sourcePaths?:string[];role:'vice_president'|'director_chat'|'director'|'employee';parentId:string|null;conversationId:string|null;phase:'chat'|'planning'|'waiting'|'reviewing'|'finished'|'work';title:string}
export interface ChatProposal {projectId:string;title:string;objective:string;deliverable:string;taskId?:string}
export interface ChatMessage {id:string;role:'user'|'assistant';content:string;taskId:string;createdAt:string;proposals:ChatProposal[]}
export interface Conversation {id:string;projectId:string|null;provider:z.infer<typeof Provider>;messages:ChatMessage[];createdAt:string}
export const ChatReply=z.object({reply:z.string().min(1).max(20000),proposals:z.array(z.object({projectId:Id,title:z.string().min(1).max(200),objective:z.string().min(1).max(10000),deliverable:z.string().min(1).max(2000)})).max(8)});
export const TeamPlan=z.object({summary:z.string().min(1).max(3000),assignments:z.array(z.object({title:z.string().min(1).max(200),objective:z.string().min(1).max(10000),output:z.string().min(1).max(2000),sourcePaths:z.array(z.string().min(1).max(500)).max(20).optional()})).min(2).max(4)});
export interface Task extends TaskInput {work?:WorkAssignment; id: string; workspaceId: string; version: number; requirementsVersion: number; status: TaskStatus; reason: string; createdAt: string; updatedAt: string; plans: Plan[]; runs: Run[]; events: Event[]; artifacts: Artifact[]; verifications: Verification[]; actions: Action[]; approvals: Approval[] }
export interface Project {provider?:z.infer<typeof Provider>;maxWorkers?:number; id: string; name: string; description: string; instructions: string; classification: z.infer<typeof Classification>; createdAt: string }
export const MemoryInput = z.object({ kind: z.enum(['Preference','Instruction','ProjectFact','Correction','Procedure','Episode']), scope: z.enum(['task','project','workspace','user-global']), scopeId: Id.nullable(), content: z.string().trim().min(1).max(10000), evidence: z.string().trim().min(1).max(3000), classification: Classification, expiresAt: z.string().datetime().nullable(), explicit: z.boolean().default(false) });
export interface Memory extends z.infer<typeof MemoryInput> { id: string; version: number; state: 'proposed' | 'active' | 'revoked' | 'expired'; createdAt: string; updatedAt: string }
export interface Device { id: string; name: string; publicKey: string; status: 'active' | 'revoked'; lastSeenAt: string; createdAt: string }
export interface Connector { id: string; kind: 'github'; name: string; account: string; resource: string; enabled: boolean }
export const ScheduleInput = z.object({ taskId: Id, cron: z.string().min(5).max(120), timezone: z.string().max(100), overlap: z.enum(['skip','wait']), misfire: z.enum(['skip','once']), enabled: z.boolean() });
export interface Schedule extends z.infer<typeof ScheduleInput> { id: string; nextAt: string; lastAt: string | null }
export interface Audit { id: string; actor: string; operation: string; target: string; traceId: string; at: string }
export interface State {conversations?:Conversation[]; schemaVersion: 1; workspaceId: string; revision: number; tasks: Task[]; projects: Project[]; memories: Memory[]; tombstones: {id: string; deletedAt: string}[]; devices: Device[]; connectors: Connector[]; schedules: Schedule[]; operations: Record<string,{hash: string; at: string}>; audit: Audit[] }
export interface Actor { id: string; role: 'user' | 'runner' | 'scheduler'; deviceId?: string }
const Versioned = { taskId: Id, expectedVersion: z.number().int().positive() };
const Leased = { taskId: Id, runId: Id, fencingToken: z.number().int().positive() };
export const Command = z.discriminatedUnion('type', [
  z.object({type:z.literal('chat.send'),id:Id,conversationId:Id,projectId:Id.nullable(),provider:Provider,content:z.string().trim().min(1).max(30000)}),
  z.object({type:z.literal('chat.result'),...Leased,reply:ChatReply}),
  z.object({type:z.literal('chat.delegate'),conversationId:Id,messageId:Id,proposalIndex:z.number().int().min(0).max(7),id:Id}),
  z.object({type:z.literal('team.plan'),...Leased,plan:TeamPlan}),
  z.object({type:z.literal('team.reviewed'),...Leased}),
  z.object({type:z.literal('task.create'), id:Id, input:TaskInput}),
  z.object({type:z.literal('task.revise'), ...Versioned, input:TaskInput}),
  z.object({type:z.literal('task.queue'), ...Versioned}),
  z.object({type:z.literal('task.control'), ...Versioned, action:z.enum(['pause','cancel','resume'])}),
  z.object({type:z.literal('run.claim'), taskId:Id, runnerId:Id}),
  z.object({type:z.literal('run.renew'), ...Leased}),
  z.object({type:z.literal('run.release'), ...Leased}),
  z.object({type:z.literal('run.event'), ...Leased, eventId:Id, sequence:z.number().int().positive(), kind:z.string().max(100), message:z.string().max(10000)}),
  z.object({type:z.literal('run.update'), ...Leased, status:TaskStatus.optional(), reason:z.string().max(2000).optional(), sessionId:z.string().max(500).optional(), model:z.string().max(120).optional(), adapterVersion:z.string().max(100).optional(), calls:z.number().int().nonnegative().optional(), tokens:z.number().int().nonnegative().optional(), costUsd:z.number().nonnegative().nullable().optional()}),
  z.object({type:z.literal('run.reserve'), ...Leased,tokens:z.number().int().positive().max(2000000).optional(),calls:z.number().int().min(1).max(100).optional()}),
  z.object({type:z.literal('run.settle'),...Leased,tokens:z.number().int().nonnegative(),calls:z.number().int().nonnegative(),costUsd:z.number().nonnegative().nullable()}),
  z.object({type:z.literal('team.review.resume'),...Versioned,additionalTokens:z.number().int().min(1000).max(60000).default(40000)}),
  z.object({type:z.literal('artifact.add'), ...Leased, id:Id, name:ArtifactName, content:z.string().max(2000000), mediaType:z.enum(['text/plain','text/markdown','application/json','text/calendar','text/javascript','text/csv','text/html'])}),
  z.object({type:z.literal('artifact.stored'), ...Leased, artifactId:Id, key:z.string().max(1000), hash:z.string().length(64)}),
  z.object({type:z.literal('verification.record'), ...Leased, criterionId:Id, passed:z.boolean(), evidence:z.string().min(1).max(10000), environment:z.enum(['local','container','cloud'])}),
  z.object({type:z.literal('verification.accept'), ...Versioned, criterionId:Id, passed:z.boolean(), evidence:z.string().min(1).max(3000)}),
  z.object({type:z.literal('run.complete'), ...Leased}),
  z.object({type:z.literal('action.propose'), ...Versioned, connectorId:Id, target:z.string().regex(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/), title:z.string().min(1).max(200), body:z.string().max(50000), idempotencyKey:z.string().min(1).max(200)}),
  z.object({type:z.literal('approval.decide'), ...Versioned, approvalId:Id, hash:z.string().length(64), decision:z.enum(['approved','denied'])}),
  z.object({type:z.literal('action.begin'), ...Leased, actionId:Id}),
  z.object({type:z.literal('action.result'), ...Leased, actionId:Id, outcome:z.enum(['succeeded','unknown']), externalId:z.string().max(200).nullable(), resultUrl:z.string().url().nullable()}),
  z.object({type:z.literal('action.reconcile'), ...Versioned, actionId:Id, externalId:z.string().min(1).max(200), resultUrl:z.string().url()}),
  z.object({type:z.literal('project.save'), id:Id, name:z.string().min(1).max(200), description:z.string().max(5000), instructions:z.string().max(10000), classification:Classification,provider:Provider.optional(),maxWorkers:z.number().int().min(2).max(4).optional()}),
  z.object({type:z.literal('memory.save'), id:Id, expectedVersion:z.number().int().nonnegative(), input:MemoryInput}),
  z.object({type:z.literal('memory.state'), id:Id, expectedVersion:z.number().int().positive(), state:z.enum(['active','revoked'])}),
  z.object({type:z.literal('memory.delete'), id:Id, expectedVersion:z.number().int().positive()}),
  z.object({type:z.literal('connector.save'), id:Id, name:z.string().min(1).max(200), account:z.string().max(100), resource:z.string().regex(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/), enabled:z.boolean()}),
  z.object({type:z.literal('device.register'), id:Id, name:z.string().min(1).max(200), publicKey:z.string().min(1).max(5000)}),
  z.object({type:z.literal('device.revoke'), id:Id}),
  z.object({type:z.literal('schedule.save'), id:Id, input:ScheduleInput}),
  z.object({type:z.literal('schedule.tick')})
]);
export type Command = z.infer<typeof Command>;
export const Envelope = z.object({ operationId:Id, command:Command });
export type Envelope = z.infer<typeof Envelope>;
export const AgentOutput = z.object({ summary:z.string().min(1).max(20000), artifacts:z.array(z.object({name:ArtifactName, content:z.string().max(2000000), mediaType:z.enum(['text/plain','text/markdown','application/json','text/calendar','text/javascript','text/csv','text/html'])})).min(1).max(20), memoryCandidates:z.array(z.object({content:z.string().max(2000), evidence:z.string().max(1000)})).max(10) });
export type AgentOutput = z.infer<typeof AgentOutput>;
export const AgentOutputJsonSchema = z.toJSONSchema(AgentOutput);
(AgentOutputJsonSchema.properties!.artifacts as {items:{properties:{name:{pattern:string}}}}).items.properties.name.pattern=providerArtifactNamePattern;
