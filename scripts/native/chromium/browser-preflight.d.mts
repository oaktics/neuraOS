import type {EventEmitter} from 'node:events';
export function validateBrowserConfiguration(plist: Record<string, unknown>, options: {data:string;endpoint:string}): void;
export function browserPreflight(app:string, options:{data:string;endpoint:string}): Promise<string>;
export function monitorBrowserChild(child:EventEmitter): {check():void;race<T>(promise:Promise<T>):Promise<T>};
