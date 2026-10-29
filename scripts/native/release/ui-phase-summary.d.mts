export const uiPhaseIDs:string[];
interface Phase {phase:string;state:string;elapsedMs:number;index?:number;deadlineMs?:number}
interface Summary {timeoutMs:number;lastStarted:Phase|null;lastCompleted:Phase|null;deadlines:{phase:string;index?:number;deadlineMs?:number;expectedByElapsedMs:number|null}[]}
export function summarizePhases(text:string, timeoutMs?:number):Summary;
export function uiFailureSummary(directory:string, timeoutMs?:number):Promise<Summary & {evidence:string;phases:string;sample:string;diagnostic:string}>;
