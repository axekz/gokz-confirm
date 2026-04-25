/**
 * gokz_confirm - Rules confirmation gate for GOKZ servers
 *
 * Players who have never confirmed the server rules are shown the
 * rules display and must type the exact confirmation phrase in chat
 * before they can start the timer. Their confirmation is recorded in a
 * SQLite database (zero-config, created on demand).
 *
 * Database schema:
 *   confirmations(
 *     steamid64   TEXT PRIMARY KEY,
 *     name        TEXT,
 *     phrase      TEXT,                -- what they actually typed
 *     created_at  INTEGER,             -- unix epoch UTC, first confirm
 *     updated_at  INTEGER              -- unix epoch UTC, last seen/confirm
 *   )
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <gokz/core>

#define PLUGIN_VERSION "1.0.0"
#define DB_NAME "gokz_confirm"   // addons/sourcemod/data/sqlite/gokz_confirm.sq3
#define REMINDER_TIME 60.0

public Plugin myinfo =
{
    name        = "GOKZ Rules Confirmation",
    author      = "cinyan10",
    description = "Blocks timer starts for unconfirmed players and shows the rules panel until they confirm.",
    version     = PLUGIN_VERSION,
    url         = ""
};

Database g_hDB = null;
bool     g_bConfirmed[MAXPLAYERS + 1];
bool     g_bChecked[MAXPLAYERS + 1];   // DB lookup completed
int      g_iLastBlockedStartCourse[MAXPLAYERS + 1];
Handle   g_hReminderTimer[MAXPLAYERS + 1];
ArrayList g_aConfirmationPhrases = null;

public void OnPluginStart()
{
    LoadTranslations("common.phrases");
    LoadTranslations("gokz-confirm.phrases");
    LoadConfirmationPhrases();

    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

    AddCommandListener(OnSayCommand, "say");
    AddCommandListener(OnSayCommand, "say_team");

    RegConsoleCmd("sm_rules",     Cmd_ShowRules,       "Show the server rules again");
    RegConsoleCmd("sm_confirm",   Cmd_ShowRules,       "Show the rules / confirmation panel");

    InitDatabase();

    // Late load
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            OnClientPostAdminCheck(i);
        }
    }
}

public void OnPluginEnd()
{
    delete g_aConfirmationPhrases;

    for (int i = 1; i <= MaxClients; i++)
    {
        KillReminderTimer(i);
        if (IsClientInGame(i))
        {
            ClearRulesDisplay(i);
        }
    }
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

void InitDatabase()
{
    // SQLite only, zero configuration.
    // SQLite_UseDatabase connects to a database by short name; the file is
    // created on demand in addons/sourcemod/data/sqlite/<name>.sq3
    char err[256];
    g_hDB = SQLite_UseDatabase(DB_NAME, err, sizeof(err));

    if (g_hDB == null)
    {
        SetFailState("[gokz_confirm] Could not open SQLite database '%s': %s", DB_NAME, err);
        return;
    }

    // Timestamps: SQLite has no native "timestamp with timezone".
    // We store Unix epoch seconds (UTC) as INTEGER - timezone-agnostic,
    // compact, indexable, and trivial to convert anywhere.
    char sQuery[] = "CREATE TABLE IF NOT EXISTS confirmations (steamid64 TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL DEFAULT '', phrase TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)";

    if (!SQL_FastQuery(g_hDB, sQuery))
    {
        char err2[256];
        SQL_GetError(g_hDB, err2, sizeof(err2));
        SetFailState("[gokz_confirm] Failed to create table: %s", err2);
    }
}

// ---------------------------------------------------------------------------
// Client lifecycle
// ---------------------------------------------------------------------------

public void OnClientPutInServer(int client)
{
    g_bConfirmed[client] = false;
    g_bChecked[client]   = false;
    g_iLastBlockedStartCourse[client] = -1;
    g_hReminderTimer[client] = null;
}

public void OnClientDisconnect(int client)
{
    KillReminderTimer(client);
    ClearRulesDisplay(client);
    g_bConfirmed[client] = false;
    g_bChecked[client]   = false;
    g_iLastBlockedStartCourse[client] = -1;
}

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client)) return;
    if (g_hDB == null) return;

    char sid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, sid64, sizeof(sid64)))
        return;

    char sQuery[256];
    FormatEx(sQuery, sizeof(sQuery),
        "SELECT phrase FROM confirmations WHERE steamid64 = '%s' LIMIT 1", sid64);

    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    dp.WriteString(sid64);

    g_hDB.Query(OnCheckConfirmed, sQuery, dp, DBPrio_Normal);
}

public void OnCheckConfirmed(Database db, DBResultSet rs, const char[] error, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    char sid64[32];
    dp.ReadString(sid64, sizeof(sid64));
    delete dp;

    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client)) return;

    if (rs == null)
    {
        LogError("[gokz_confirm] DB check failed for %L: %s", client, error);
        // Fail-open? No - we fail-closed: treat as unconfirmed and show rules.
        g_bChecked[client] = true;
        g_bConfirmed[client] = false;
        return;
    }

    g_bChecked[client] = true;
    g_bConfirmed[client] = rs.FetchRow(); // any row => already confirmed

    if (!g_bConfirmed[client])
    {
        // Brand new player - show rules on next spawn (or immediately if alive).
        if (IsPlayerAlive(client))
        {
            ShowRulesDisplay(client, true);
            StartReminderTimer(client);
        }
    }
}

// ---------------------------------------------------------------------------
// Spawn hook - show rules to unconfirmed players
// ---------------------------------------------------------------------------

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client)) return;

    if (g_bConfirmed[client]) return;

    RequestFrame(NextFrame_ShowRules, GetClientUserId(client));
}

void NextFrame_ShowRules(int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client)) return;
    if (!IsPlayerAlive(client)) return;
    if (g_bConfirmed[client]) return;

    ShowRulesDisplay(client, true);
    StartReminderTimer(client);
}

// ---------------------------------------------------------------------------
// Timer gate
// ---------------------------------------------------------------------------

public Action GOKZ_OnTimerStart(int client, int course)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Continue;
    }
    if (g_bConfirmed[client])
    {
        return Plugin_Continue;
    }

    if (g_iLastBlockedStartCourse[client] != course)
    {
        g_iLastBlockedStartCourse[client] = course;
        GOKZ_PrintToChat(client, true, "{red}%t", "rules timer blocked");
        ShowRulesDisplay(client, true);
    }

    StartReminderTimer(client);
    return Plugin_Stop;
}

public void GOKZ_OnTeleportToStart_Post(int client, int course)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    g_iLastBlockedStartCourse[client] = -1;
}

// ---------------------------------------------------------------------------
// Rules display
// ---------------------------------------------------------------------------

void ShowRulesDisplay(int client, bool announceChat)
{
    char title[128];
    char rules[1024];
    char prompt[256];
    char confirmPhrase[256];

    GetTranslatedPhrase(client, "rules title", "Rules Confirmation", title, sizeof(title));
    BuildRulesBody(client, rules, sizeof(rules));
    GetTranslatedPhrase(client, "rules prompt", "Type exactly in chat:", prompt, sizeof(prompt));
    GetConfirmationPhrase(client, confirmPhrase, sizeof(confirmPhrase));

    ShowRulesMenu(client, title, rules, prompt, confirmPhrase);

    if (!announceChat)
    {
        return;
    }

    if (g_bConfirmed[client])
    {
        GOKZ_PrintToChat(client, true, "{grey}%t", "rules reopened");
    }
    else
    {
        GOKZ_PrintToChat(client, true, "{grey}%t", "rules move hint");
    }
}

void ShowRulesMenu(int client, const char[] title, const char[] rules, const char[] prompt, const char[] confirmPhrase)
{
    char menuTitle[2048];
    Menu menu = new Menu(MenuHandler_RulesMenu);

    CancelClientMenu(client, true);
    FormatEx(menuTitle, sizeof(menuTitle), "%s\n \n%s\n%s\n \n%s", title, prompt, confirmPhrase, rules);

    menu.SetTitle(menuTitle);
    menu.AddItem("", " ", ITEMDRAW_DISABLED);
    menu.Pagination = MENU_NO_PAGINATION;
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_RulesMenu(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }

    return 0;
}

void BuildRulesBody(int client, char[] buffer, int maxlen)
{
    static const char phraseKeys[][] =
    {
        "rules rule 1",
        "rules rule 2",
        "rules rule 3",
        "rules rule 4",
        "rules rule 5",
        "rules rule 6"
    };
    static const char fallbackRules[][] =
    {
        "1. Do not exploit unbalanced bugs to abuse the leaderboard.\n   Applies to map bugs and plugin bugs.",
        "2. If you find a bug, DM an admin. Do not exploit it.",
        "3. Do not play on an alt account.\n   Abusing the leaderboard on an alt will result in a ban.",
        "4. Do not use cheats.",
        "5. Do not use infinite scroll wheels (for example, Logitech G502).",
        "6. Do not play on someone else's account,\n   or let others play on your account."
    };

    char line[256];
    buffer[0] = '\0';

    for (int i = 0; i < sizeof(phraseKeys); i++)
    {
        GetTranslatedPhrase(client, phraseKeys[i], fallbackRules[i], line, sizeof(line));

        if (i > 0)
        {
            StrCat(buffer, maxlen, "\n");
        }

        StrCat(buffer, maxlen, line);
    }
}

void ClearRulesDisplay(int client)
{
    if (!IsClientInGame(client))
    {
        return;
    }

    CancelClientMenu(client, true);
}

// ---------------------------------------------------------------------------
// Reminder timer - keep the rules menu visible until they confirm
// ---------------------------------------------------------------------------

void StartReminderTimer(int client)
{
    KillReminderTimer(client);
    g_hReminderTimer[client] = CreateTimer(REMINDER_TIME, Timer_Reminder,
        GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void KillReminderTimer(int client)
{
    if (g_hReminderTimer[client] != null)
    {
        KillTimer(g_hReminderTimer[client]);
        g_hReminderTimer[client] = null;
    }
}

public Action Timer_Reminder(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client))
    {
        return Plugin_Stop;
    }
    if (g_bConfirmed[client])
    {
        g_hReminderTimer[client] = null;
        return Plugin_Stop;
    }

    ShowRulesDisplay(client, false);
    return Plugin_Continue;
}

// ---------------------------------------------------------------------------
// Chat listener — catch the confirmation phrase
// ---------------------------------------------------------------------------

public Action OnSayCommand(int client, const char[] command, int args)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Continue;

    if (g_bConfirmed[client])
        return Plugin_Continue;

    char sArgs[256];
    GetCmdArgString(sArgs, sizeof(sArgs));
    StripQuotes(sArgs);
    TrimString(sArgs);

    if (MatchesConfirmationPhrase(client, sArgs))
    {
        ConfirmPlayer(client, sArgs);
        return Plugin_Continue;
    }

    return Plugin_Continue;
}

bool MatchesLoosely(const char[] got, const char[] want)
{
    // Allow trailing '.' or '!' etc.
    int lenG = strlen(got);
    int lenW = strlen(want);
    if (lenG < lenW) return false;
    if (strncmp(got, want, lenW, false) != 0) return false;
    for (int i = lenW; i < lenG; i++)
    {
        if (got[i] != '.' && got[i] != '!' && got[i] != ' ')
            return false;
    }
    return true;
}

void GetConfirmationPhrase(int client, char[] buffer, int maxlen)
{
    GetTranslatedPhrase(client, "confirm phrase", "I won't exploit the bug to abuse the leaderboard", buffer, maxlen);
}

void LoadConfirmationPhrases()
{
    delete g_aConfirmationPhrases;
    g_aConfirmationPhrases = new ArrayList(ByteCountToCells(256));

    AddConfirmationPhrase("I won't exploit the bug to abuse the leaderboard");

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "translations/gokz-confirm.phrases.txt");

    KeyValues kv = new KeyValues("Phrases");
    if (!kv.ImportFromFile(path))
    {
        delete kv;
        return;
    }

    if (!kv.JumpToKey("confirm phrase"))
    {
        delete kv;
        return;
    }

    if (kv.GotoFirstSubKey(false))
    {
        char phrase[256];
        do
        {
            kv.GetString(NULL_STRING, phrase, sizeof(phrase));
            TrimString(phrase);
            AddConfirmationPhrase(phrase);
        }
        while (kv.GotoNextKey(false));
    }

    delete kv;
}

void AddConfirmationPhrase(const char[] phrase)
{
    if (phrase[0] == '\0')
    {
        return;
    }

    char existingPhrase[256];
    for (int phraseIndex = 0; phraseIndex < g_aConfirmationPhrases.Length; phraseIndex++)
    {
        g_aConfirmationPhrases.GetString(phraseIndex, existingPhrase, sizeof(existingPhrase));
        if (StrEqual(existingPhrase, phrase))
        {
            return;
        }
    }

    g_aConfirmationPhrases.PushString(phrase);
}

void GetTranslatedPhrase(int target, const char[] phrase, const char[] fallback, char[] buffer, int maxlen)
{
    if (TranslationPhraseExists(phrase))
    {
        FormatEx(buffer, maxlen, "%T", phrase, target);
        return;
    }

    strcopy(buffer, maxlen, fallback);
}

bool MatchesWantedPhrase(const char[] got, const char[] want)
{
    return StrEqual(got, want, false) || MatchesLoosely(got, want);
}

bool MatchesConfirmationPhrase(int client, const char[] got)
{
    char clientPhrase[256];
    GetConfirmationPhrase(client, clientPhrase, sizeof(clientPhrase));

    if (MatchesWantedPhrase(got, clientPhrase))
    {
        return true;
    }

    char configuredPhrase[256];
    for (int phraseIndex = 0; phraseIndex < g_aConfirmationPhrases.Length; phraseIndex++)
    {
        g_aConfirmationPhrases.GetString(phraseIndex, configuredPhrase, sizeof(configuredPhrase));
        if (MatchesWantedPhrase(got, configuredPhrase))
        {
            return true;
        }
    }

    return false;
}

// ---------------------------------------------------------------------------
// Confirm & persist
// ---------------------------------------------------------------------------

void ConfirmPlayer(int client, const char[] typedPhrase)
{
    g_bConfirmed[client] = true;
    KillReminderTimer(client);
    ClearRulesDisplay(client);

    GOKZ_PrintToChat(client, true, "{green}%t", "rules confirmed");
    GOKZ_PrintToChatAll(true, "{green}%N {grey}%t", client, "rules accepted all");

    char sid64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, sid64, sizeof(sid64)))
        return;

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    // Escape strings for SQL
    char safeName[2 * MAX_NAME_LENGTH + 1];
    char safePhrase[2 * 256 + 1];
    SQL_EscapeString(g_hDB, name,        safeName,   sizeof(safeName));
    SQL_EscapeString(g_hDB, typedPhrase, safePhrase, sizeof(safePhrase));

    int now = GetTime(); // unix epoch UTC

    // UPSERT: insert on first confirm (sets created_at), update on re-confirm
    // (refreshes name / phrase / updated_at, preserves created_at).
    char sQuery[1024];
    FormatEx(sQuery, sizeof(sQuery),
        "INSERT INTO confirmations (steamid64, name, phrase, created_at, updated_at) VALUES ('%s', '%s', '%s', %d, %d) ON CONFLICT(steamid64) DO UPDATE SET name = excluded.name, phrase = excluded.phrase, updated_at = excluded.updated_at",
        sid64, safeName, safePhrase, now, now);

    g_hDB.Query(OnConfirmWritten, sQuery, GetClientUserId(client), DBPrio_High);
}

public void OnConfirmWritten(Database db, DBResultSet rs, const char[] error, any userid)
{
    if (rs == null)
    {
        int client = GetClientOfUserId(userid);
        LogError("[gokz_confirm] Failed to persist confirmation for %s: %s",
            (client > 0) ? "client" : "?", error);
    }
}

// ---------------------------------------------------------------------------
// Manual commands
// ---------------------------------------------------------------------------

public Action Cmd_ShowRules(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client))
        return Plugin_Handled;

    ShowRulesDisplay(client, true);
    return Plugin_Handled;
}
