import {z} from 'zod';
/** A logical, relative artifact name, never a destination on the host filesystem. */
export const artifactNamePattern=/^(?![A-Za-z]:)(?:(?!\.{1,2}(?:\/|$))[^/\\\x00-\x1f\x7f-\x9f\u2028\u2029]+\/)*(?!\.{1,2}$)[^/\\\x00-\x1f\x7f-\x9f\u2028\u2029]+$(?![\s\S])/;
export const ArtifactName=z.string().min(1).max(200).regex(artifactNamePattern,'invalid_artifact_name').describe('Logical relative name, e.g. src/main.ts. No absolute paths, dot segments, backslashes or control characters. Does not write to the project.');
export const artifactDownloadName=(name:string)=>name.split('/').at(-1)!;
// Provider grammar compilers do not support lookaround. Equivalent path segments
// are described positively; the local ArtifactName remains the final validator.
const providerPart=String.raw`(?:[^./\\:\x00-\x1f\x7f-\x9f\u2028\u2029][^/\\:\x00-\x1f\x7f-\x9f\u2028\u2029]*|\.[^./\\:\x00-\x1f\x7f-\x9f\u2028\u2029][^/\\:\x00-\x1f\x7f-\x9f\u2028\u2029]*|\.\.[^/\\:\x00-\x1f\x7f-\x9f\u2028\u2029]+)`;
export const providerArtifactNamePattern=`^(?:${providerPart}/)*${providerPart}$`;
