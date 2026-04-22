export type ProviderAuthLaunchMode = "server_browser" | "phone_browser" | "none";

export type ProviderAuthFlowType = "oauth_callback" | "device_code" | "oauth";

export type ProviderAuthFlowStatus =
  | "pending"
  | "awaiting_external"
  | "awaiting_prompt"
  | "awaiting_manual_code"
  | "completed"
  | "failed"
  | "cancelled"
  | "expired";

export interface ProviderAuthInfo {
  url: string;
  instructions?: string;
}

export interface ProviderAuthPrompt {
  message: string;
  placeholder?: string;
  allowEmpty?: boolean;
}

export interface ProviderAuthFlowSnapshot {
  flowId: string;
  providerId: string;
  flowType: ProviderAuthFlowType;
  launchMode: ProviderAuthLaunchMode;
  status: ProviderAuthFlowStatus;
  auth?: ProviderAuthInfo;
  prompt?: ProviderAuthPrompt;
  lastProgress?: string;
  error?: string;
  createdAt: number;
  updatedAt: number;
  expiresAt: number;
}

export interface ProviderAuthOAuthCapabilities {
  flowType: ProviderAuthFlowType;
  supportsServerBrowserLaunch: boolean;
  supportsPhoneBrowserLaunch: boolean;
  supportsManualCodeInput: boolean;
  mayPromptForInput: boolean;
}

export interface ProviderAuthProviderInfo {
  id: string;
  name: string;
  supportsApiKey: boolean;
  oauth?: ProviderAuthOAuthCapabilities;
}

export interface ProviderAuthProviderStatus extends ProviderAuthProviderInfo {
  authenticated: boolean;
  credentialType?: "oauth" | "api_key";
  expiresAt?: number;
  maskedKey?: string;
}

export function isTerminalProviderAuthStatus(status: ProviderAuthFlowStatus): boolean {
  return (
    status === "completed" || status === "failed" || status === "cancelled" || status === "expired"
  );
}

export class ProviderAuthError extends Error {
  constructor(
    readonly statusCode: number,
    message: string,
  ) {
    super(message);
    this.name = "ProviderAuthError";
  }
}
