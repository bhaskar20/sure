// Type definitions for @sure/miniapp-sdk 1.0 (bridge version 1, protocol 2026-11-11).
//
// Tool argument types mirror the JSON schemas of Sure's assistant/MCP tools
// (`tools/list` returns the live schemas). Result types describe the fields
// apps rely on most; tools may return more.

// ---------------------------------------------------------------------------
// Permissions, errors and the handshake
// ---------------------------------------------------------------------------

export type Permission =
  | "accounts:read"
  | "transactions:read"
  | "transactions:write"
  | "categories:read"
  | "categories:write"
  | "tags:read"
  | "tags:write"
  | "merchants:read"
  | "rules:read"
  | "rules:write"
  | "reports:read"
  | "budgets:write"
  | "goals:write"
  | "valuations:write";

export type WritePolicy = "confirm" | "allow";

export declare const ErrorCodes: Readonly<{
  PARSE_ERROR: -32700;
  INVALID_REQUEST: -32600;
  /** Unknown method, or a tool that is not available to mini apps. */
  METHOD_NOT_FOUND: -32601;
  INVALID_PARAMS: -32602;
  INTERNAL_ERROR: -32603;
  /** The tool raised; the message is generic (SDK-side, from `isError: true`). */
  TOOL_ERROR: -32000;
  /** The permission is not granted. `data.permission` names it. */
  PERMISSION_DENIED: -32003;
  /** The app was disabled by an admin. */
  APP_DISABLED: -32004;
  /** Handled by the host, which asks the person; apps normally never see it. */
  CONFIRMATION_REQUIRED: -32005;
  /** The person declined the write in Sure's confirmation dialog. */
  DECLINED: -32006;
  /** More than 120 tool calls per minute for this app and user. */
  RATE_LIMITED: -32029;
  /** SDK-side: a non-tool request got no answer within its timeout. */
  TIMEOUT: -32098;
  /** SDK-side: the page is not running inside Sure. */
  NOT_EMBEDDED: -32099;
}>;

export type ErrorCode = (typeof ErrorCodes)[keyof typeof ErrorCodes] | number;

export interface PermissionDeniedData {
  permission: Permission;
}

export interface ConfirmationRequiredData {
  tool: ToolName;
  permission: Permission;
  summary: string;
  /** What the call would change, described by Sure from the real arguments. */
  details?: Array<{ label: string; value: string }>;
}

export declare class SureMiniAppError extends Error {
  constructor(code: ErrorCode, message?: string, data?: unknown);
  readonly name: "SureMiniAppError";
  readonly code: ErrorCode;
  readonly data: unknown;
}

export interface InitializeResult {
  protocolVersion: string;
  bridgeVersion: number;
  hostInfo: { name: string; version?: string };
  app: { id: string; name: string; version: string };
  /** Effective permissions for the current person (guests get reads only). */
  permissions: Permission[];
  writePolicy: WritePolicy;
  user: { name: string; role: string };
  family: { currency: string; locale: string; dateFormat: string };
  capabilities: { tools?: object; storage?: object; events?: object };
}

export interface ToolDescriptor {
  name: ToolName | string;
  description: string;
  inputSchema: Record<string, unknown>;
  permission: Permission;
  write: boolean;
}

export interface ConnectOptions {
  /** Milliseconds to wait for ui/initialize. Defaults to 30000. */
  timeout?: number;
  /** Post ui/size-changed whenever the document height changes. Defaults to true. */
  autoResize?: boolean;
}

export interface RequestOptions {
  /** Milliseconds; 0 waits forever. Defaults to 30000. */
  timeout?: number;
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

/** JSON value stored per app (≤ 256 KB per record, ≤ 5,000 records per app). */
export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

export interface StorageItem<T = JsonValue> {
  key: string;
  data: T;
  updatedAt: string;
}

export interface StorageListOptions {
  prefix?: string;
  /** 1–200. */
  limit?: number;
  cursor?: string | null;
}

export interface StorageApi {
  /** Collection: /^[a-z0-9_-]{1,64}$/. Key: 1–255 characters. Resolves null when absent. */
  get<T = JsonValue>(collection: string, key: string): Promise<T | null>;
  set<T = JsonValue>(collection: string, key: string, data: T): Promise<unknown>;
  delete(collection: string, key: string): Promise<unknown>;
  list<T = JsonValue>(
    collection: string,
    options?: StorageListOptions,
  ): Promise<{ items: StorageItem<T>[]; nextCursor: string | null }>;
}

// ---------------------------------------------------------------------------
// Shared tool shapes
// ---------------------------------------------------------------------------

/** Tools report expected failures as a value rather than a JSON-RPC error. */
export interface ToolFailure {
  success: false;
  error: string;
  message: string;
}

export interface ToolSuccess {
  success: true;
  message?: string;
}

export interface Paginated {
  total_results: number;
  page: number;
  page_size: number;
  total_pages: number;
}

export interface PageParams {
  page?: number;
  /** 1–100. */
  page_size?: number;
}

/** YYYY-MM-DD */
export type DateString = string;

// ---------------------------------------------------------------------------
// Accounts and valuations
// ---------------------------------------------------------------------------

export interface GetAccountsArgs {
  include_balance_series?: boolean;
  series_period?: string;
}

export interface Account {
  id: string;
  name: string;
  balance: number | string;
  currency: string;
  balance_formatted: string;
  classification: "asset" | "liability";
  type: string;
  subtype: string | null;
  start_date: DateString | null;
  is_linked: boolean;
  provider: string | null;
  status: string;
  [key: string]: unknown;
}

export interface GetAccountsResult {
  as_of_date: DateString;
  accounts: Account[];
  [key: string]: unknown;
}

export interface GetHoldingsArgs {
  page: number;
  /** Investment or crypto account names. */
  accounts?: string[];
  /** Security tickers. */
  securities?: string[];
}

export interface GetValuationsArgs {
  account_id?: string;
  start_date?: DateString;
  end_date?: DateString;
  page?: number;
}

export interface RecordValuationArgs {
  account_id: string;
  date: DateString;
  amount: number;
  source: string;
}

export interface SetOpeningBalanceArgs {
  account_id: string;
  balance: number;
  date?: DateString;
  dry_run?: boolean;
}

// ---------------------------------------------------------------------------
// Transactions and transfers
// ---------------------------------------------------------------------------

export interface GetTransactionsArgs extends PageParams {
  order?: "asc" | "desc";
  sort_by?: "date" | "amount";
  search?: string;
  /** Used together with amount_operator. */
  amount?: string;
  amount_operator?: "equal" | "less" | "greater";
  start_date?: DateString;
  end_date?: DateString;
  types?: Array<"income" | "expense" | "transfer">;
  statuses?: Array<"pending" | "confirmed">;
  account_ids?: string[];
  /** Exact account names. */
  accounts?: string[];
  /** Exact category names; "Uncategorized" is accepted. */
  categories?: string[];
  merchants?: string[];
  tags?: string[];
}

export interface Transaction {
  id: string;
  entry_id: string;
  name: string;
  date: DateString;
  /** Always positive; read `classification` for the direction. */
  amount: number | string;
  currency: string;
  formatted_amount: string;
  classification: "income" | "expense";
  account: string;
  notes: string | null;
  /** Category name, or null when uncategorized. */
  category: string | null;
  merchant: string | null;
  tags: string[];
  is_transfer: boolean;
  kind: string;
  pending?: true;
  excluded?: true;
  transfer_account?: string;
  clean_name?: string;
  rail?: string;
  operation_date?: DateString;
}

export interface GetTransactionsResult extends Paginated {
  transactions: Transaction[];
  total_income: string;
  total_expenses: string;
}

export interface GetRecurringTransactionsArgs {
  status?: "active" | "inactive" | "all";
  /** 1–365. */
  upcoming_within_days?: number;
}

export interface GetUncategorizedTransactionsArgs {
  start_date?: DateString;
  end_date?: DateString;
  account_ids?: string[];
  limit?: number;
}

export interface GetTransferMatchCandidatesArgs {
  transaction_id: string;
}

export interface CreateTransactionArgs {
  account_id: string;
  date: DateString;
  amount: number;
  name: string;
  type?: "income" | "expense" | "inflow" | "outflow";
  currency?: string;
  notes?: string | null;
  category_id?: string | null;
  merchant_id?: string | null;
  tag_ids?: string[];
  external_id?: string;
  source?: string;
  user_modified?: boolean;
}

export interface UpdateTransactionArgs {
  /** Transaction id from get_transactions. */
  id: string;
  name?: string;
  /** null clears the notes. */
  notes?: string | null;
  /** Category id from get_categories; null clears the category. */
  category_id?: string | null;
  merchant_id?: string | null;
  /** Full list of tag ids; [] clears all tags. */
  tag_ids?: string[];
}

export interface UpdatedTransaction {
  id: string;
  name: string;
  date: DateString;
  notes: string | null;
  category: { id: string; name: string } | null;
  merchant: { id: string; name: string } | null;
  tags: Array<{ id: string; name: string }>;
}

export type UpdateTransactionResult =
  | (ToolSuccess & { transaction: UpdatedTransaction })
  | ToolFailure;

export interface DeleteTransactionArgs {
  id: string;
  account_id?: string;
}

export interface MatchTransferArgs {
  transaction_id: string;
  counterpart_transaction_id?: string;
  target_account_id?: string;
  dry_run?: boolean;
}

export interface UnmatchTransferArgs {
  transaction_id?: string;
  transfer_id?: string;
  reject?: boolean;
  dry_run?: boolean;
}

export interface UpdateTransferArgs {
  transaction_id?: string;
  transfer_id?: string;
  investment_contribution?: boolean;
  dry_run?: boolean;
}

export interface ReviewTransferArgs {
  transfer_id: string;
  action: "confirm" | "reject";
}

// ---------------------------------------------------------------------------
// Categories, tags, merchants
// ---------------------------------------------------------------------------

export interface Category {
  id: string;
  name: string;
  name_with_parent: string;
  color: string;
  icon: string;
  parent_id: string | null;
  is_subcategory?: boolean;
}

export interface GetCategoriesResult extends Paginated {
  categories: Category[];
}

export interface CreateCategoryArgs {
  /** Unique within the family. */
  name: string;
  /** Hex color such as #e99537; ignored for subcategories. */
  color?: string;
  /** Lucide icon name; suggested from the name when omitted. */
  icon?: string;
  /** A top-level category id to nest under. */
  parent_id?: string;
}

export type CreateCategoryResult =
  | (ToolSuccess & { category: Category })
  | ToolFailure;

export interface UpdateCategoryArgs {
  id: string;
  name?: string;
  color?: string;
  icon?: string;
  parent_id?: string;
}

export interface DeleteCategoryArgs {
  id: string;
  /** Category that receives the deleted category's transactions. */
  replacement_id?: string;
}

export interface Tag {
  id: string;
  name: string;
  color: string;
}

export interface GetTagsResult extends Paginated {
  tags: Tag[];
}

export interface CreateTagArgs {
  name: string;
  color?: string;
}

export interface UpdateTagArgs {
  /** Current tag name. */
  name: string;
  new_name?: string;
  color?: string;
}

export interface GetMerchantsArgs extends PageParams {
  search?: string;
}

export interface Merchant {
  id: string;
  name: string;
  source: "family" | "provider";
}

export interface GetMerchantsResult extends Paginated {
  merchants: Merchant[];
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

export interface RuleCondition {
  /** A condition key from get_rule_options, or "compound". */
  condition_type: string;
  /** An operator from get_rule_options; "and" or "or" for compound. */
  operator: string;
  value?: string;
  sub_conditions?: RuleCondition[];
}

export interface RuleAction {
  /** An action key from get_rule_options. */
  action_type: string;
  value?: string | string[];
}

export interface RuleDefinition {
  conditions?: RuleCondition[];
  actions?: RuleAction[];
  effective_date?: DateString;
}

export interface GetRulesArgs extends PageParams {
  rule_id?: string;
  active?: boolean;
  search?: string;
}

export interface PreviewRuleArgs extends RuleDefinition {
  rule_id?: string;
  /** Up to 25. */
  sample_size?: number;
}

export interface CreateRuleArgs extends RuleDefinition {
  conditions: RuleCondition[];
  actions: RuleAction[];
  name?: string;
  sample_size?: number;
}

export interface UpdateRuleArgs extends RuleDefinition {
  rule_id: string;
  name?: string;
  /** Only false is accepted. */
  active?: false;
  sample_size?: number;
}

export interface ApplyRuleArgs {
  rule_id: string;
  /** From preview_rule, create_rule or update_rule. */
  preview_token: string;
  override_locked?: boolean;
}

// ---------------------------------------------------------------------------
// Reports, budgets, goals
// ---------------------------------------------------------------------------

export interface GetBalanceSheetArgs {
  period?: string;
  start_date?: DateString;
  end_date?: DateString;
  interval?: string;
}

export interface GetIncomeStatementArgs {
  start_date: DateString;
  end_date: DateString;
  account_ids?: string[];
  group_by?: "none" | "month";
  compare_previous_period?: boolean;
}

export interface GetBudgetArgs {
  /** YYYY-MM. */
  month?: string;
  prior_months?: number;
}

export interface GetInsightsArgs {
  insight_type?: string;
  include_acknowledged?: boolean;
  limit?: number;
}

export interface UpdateBudgetArgs {
  /** YYYY-MM. */
  month?: string;
  budgeted_spending?: number;
  expected_income?: number;
  categories?: Array<{ category: string; amount: number }>;
}

export interface CreateGoalArgs {
  name: string;
  target_amount: number;
  target_date?: DateString;
  linked_account_names: string[];
  earmarks?: Record<string, unknown>;
  notes?: string;
}

// ---------------------------------------------------------------------------
// Tool map
// ---------------------------------------------------------------------------

type Loose = Record<string, unknown>;

export interface ToolMap {
  get_accounts: { args: GetAccountsArgs; result: GetAccountsResult };
  get_holdings: { args: GetHoldingsArgs; result: Loose };
  get_valuations: { args: GetValuationsArgs; result: Loose };
  record_valuation: { args: RecordValuationArgs; result: Loose };
  set_opening_balance: { args: SetOpeningBalanceArgs; result: Loose };

  get_transactions: { args: GetTransactionsArgs; result: GetTransactionsResult };
  get_recurring_transactions: { args: GetRecurringTransactionsArgs; result: Loose };
  get_uncategorized_transactions: { args: GetUncategorizedTransactionsArgs; result: Loose };
  get_transfer_match_candidates: { args: GetTransferMatchCandidatesArgs; result: Loose };
  create_transaction: { args: CreateTransactionArgs; result: Loose };
  update_transaction: { args: UpdateTransactionArgs; result: UpdateTransactionResult };
  delete_transaction: { args: DeleteTransactionArgs; result: Loose };
  match_transfer: { args: MatchTransferArgs; result: Loose };
  unmatch_transfer: { args: UnmatchTransferArgs; result: Loose };
  update_transfer: { args: UpdateTransferArgs; result: Loose };
  review_transfer: { args: ReviewTransferArgs; result: Loose };

  get_categories: { args: PageParams; result: GetCategoriesResult };
  create_category: { args: CreateCategoryArgs; result: CreateCategoryResult };
  update_category: { args: UpdateCategoryArgs; result: Loose };
  delete_category: { args: DeleteCategoryArgs; result: Loose };

  get_tags: { args: PageParams; result: GetTagsResult };
  create_tag: { args: CreateTagArgs; result: (ToolSuccess & { tag: Tag }) | ToolFailure };
  update_tag: { args: UpdateTagArgs; result: Loose };

  get_merchants: { args: GetMerchantsArgs; result: GetMerchantsResult };

  get_rules: { args: GetRulesArgs; result: Loose };
  get_rule_options: { args: Record<string, never>; result: Loose };
  preview_rule: { args: PreviewRuleArgs; result: Loose };
  create_rule: { args: CreateRuleArgs; result: Loose };
  update_rule: { args: UpdateRuleArgs; result: Loose };
  apply_rule: { args: ApplyRuleArgs; result: Loose };

  get_balance_sheet: { args: GetBalanceSheetArgs; result: Loose };
  get_income_statement: { args: GetIncomeStatementArgs; result: Loose };
  get_budget: { args: GetBudgetArgs; result: Loose };
  get_insights: { args: GetInsightsArgs; result: Loose };
  update_budget: { args: UpdateBudgetArgs; result: Loose };
  create_goal: { args: CreateGoalArgs; result: Loose };
}

export type ToolName = keyof ToolMap;
export type ToolArgs<N extends ToolName> = ToolMap[N]["args"];
export type ToolResult<N extends ToolName> = ToolMap[N]["result"];

type Helper<N extends ToolName> = (args?: ToolArgs<N>) => Promise<ToolResult<N>>;
type RequiredHelper<N extends ToolName> = (args: ToolArgs<N>) => Promise<ToolResult<N>>;

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

export interface DataChangedEvent {
  tool: ToolName | string;
}

export interface SureMiniAppClient {
  readonly info: InitializeResult;
  readonly protocolVersion: string;
  readonly bridgeVersion: number;
  readonly app: InitializeResult["app"];
  readonly user: InitializeResult["user"];
  readonly family: InitializeResult["family"];
  readonly permissions: readonly Permission[];
  readonly writePolicy: WritePolicy;
  readonly capabilities: InitializeResult["capabilities"];

  /** True when the permission is effective for the person using the app. */
  can(permission: Permission): boolean;

  /**
   * Calls a tool (MCP `tools/call`) and resolves its structuredContent.
   * Never times out: a write may wait for the person to confirm it.
   */
  call<N extends ToolName>(name: N, args?: ToolArgs<N>): Promise<ToolResult<N>>;
  call(name: string, args?: Record<string, unknown>): Promise<unknown>;

  /** Sends any bridge method. Rejects with SureMiniAppError. */
  request<T = unknown>(method: string, params?: object, options?: RequestOptions): Promise<T>;
  ping(): Promise<Record<string, never>>;

  tools: { list(): Promise<ToolDescriptor[]> };

  accounts: {
    list: Helper<"get_accounts">;
    holdings: RequiredHelper<"get_holdings">;
    valuations: Helper<"get_valuations">;
    recordValuation: RequiredHelper<"record_valuation">;
    setOpeningBalance: RequiredHelper<"set_opening_balance">;
  };
  transactions: {
    list: Helper<"get_transactions">;
    recurring: Helper<"get_recurring_transactions">;
    uncategorized: Helper<"get_uncategorized_transactions">;
    transferCandidates: RequiredHelper<"get_transfer_match_candidates">;
    create: RequiredHelper<"create_transaction">;
    update: RequiredHelper<"update_transaction">;
    delete: RequiredHelper<"delete_transaction">;
    matchTransfer: RequiredHelper<"match_transfer">;
    unmatchTransfer: RequiredHelper<"unmatch_transfer">;
    updateTransfer: RequiredHelper<"update_transfer">;
    reviewTransfer: RequiredHelper<"review_transfer">;
  };
  categories: {
    list: Helper<"get_categories">;
    create: RequiredHelper<"create_category">;
    update: RequiredHelper<"update_category">;
    delete: RequiredHelper<"delete_category">;
  };
  tags: {
    list: Helper<"get_tags">;
    create: RequiredHelper<"create_tag">;
    update: RequiredHelper<"update_tag">;
  };
  merchants: {
    list: Helper<"get_merchants">;
  };
  rules: {
    list: Helper<"get_rules">;
    options: Helper<"get_rule_options">;
    preview: Helper<"preview_rule">;
    create: RequiredHelper<"create_rule">;
    update: RequiredHelper<"update_rule">;
    apply: RequiredHelper<"apply_rule">;
  };
  reports: {
    balanceSheet: Helper<"get_balance_sheet">;
    incomeStatement: RequiredHelper<"get_income_statement">;
    budget: Helper<"get_budget">;
    insights: Helper<"get_insights">;
  };
  budgets: {
    get: Helper<"get_budget">;
    update: Helper<"update_budget">;
  };
  goals: {
    create: RequiredHelper<"create_goal">;
  };

  storage: StorageApi;

  /** Fires after a successful write by this app (`notifications/sure/data_changed`). */
  on(event: "dataChanged", handler: (event: DataChangedEvent) => void): () => void;
  /** Subscribes to any host notification by its JSON-RPC method name. */
  on(method: string, handler: (params: Record<string, unknown>) => void): () => void;

  /** Stops auto-resize and rejects pending requests. */
  close(): void;
}

export declare function connect(options?: ConnectOptions): Promise<SureMiniAppClient>;
export declare const version: string;
export declare const protocolVersion: string;

export interface SureMiniAppGlobal {
  readonly version: string;
  readonly protocolVersion: string;
  readonly ErrorCodes: typeof ErrorCodes;
  readonly SureMiniAppError: typeof SureMiniAppError;
  connect(options?: ConnectOptions): Promise<SureMiniAppClient>;
}

declare const SureMiniApp: SureMiniAppGlobal;
export default SureMiniApp;

declare global {
  interface Window {
    SureMiniApp: SureMiniAppGlobal;
  }
}
