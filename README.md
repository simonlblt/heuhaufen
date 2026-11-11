# Heuhaufen

Das Ratespiel, bei dem seltene Antworten die meisten Punkte bringen – mit Tagesrätsel und Bestenliste. Spielbar ohne Anmeldung.

**Hier spielen:** https://simonlblt.github.io/heuhaufen/

## Dateien

| Datei | Wofür |
|---|---|
| `index.html` | Das komplette Spiel |
| `config.js` | Verbindung zur Bestenliste (Supabase-Adresse und öffentlicher Schlüssel) |
| `supabase.sql` | Einrichtungs-Skript für die Datenbank (Tagesrätsel) |
| `duell.sql` | Einrichtungs-Skript für das Duell |
| `profil.sql` | Einrichtungs-Skript für Spielerprofile und Match-Historie |
| `konto.sql` | Einrichtungs-Skript für Profile mit Name und Passwort |

## Einrichten (einmalig, kostenlos)

### 1. Datenbank für die Bestenliste (Supabase)

1. Auf [supabase.com](https://supabase.com) kostenlos registrieren und **New project** anlegen (Name z. B. `heuhaufen`, Region **Frankfurt**). Das Datenbank-Passwort brauchst du für das Spiel nicht.
2. Links **SQL Editor** öffnen, den kompletten Inhalt von `supabase.sql` einfügen und **Run** klicken.
3. Unter **Project Settings → API Keys** (bzw. **API**) diese zwei Werte kopieren:
   - die **Project URL** (sieht aus wie `https://abcdefghijkl.supabase.co`)
   - den **öffentlichen Schlüssel**: „publishable“ (`sb_publishable_…`) oder bei älteren Projekten „anon public“ (beginnt mit `eyJ`)
4. Beide Werte in `config.js` eintragen.

> Niemals den **secret**- bzw. **service_role**-Schlüssel verwenden oder weitergeben. Der öffentliche Schlüssel darf auf der Website stehen – die Datenbank lässt damit nur die vier Spiel-Aktionen zu.

### 2. Website (GitHub Pages)

1. Auf GitHub ein **öffentliches** Repository anlegen, z. B. `heuhaufen`.
2. Die drei Dateien hochladen (`index.html`, `config.js`, `supabase.sql`, gerne auch diese `README.md`).
3. **Settings → Pages → Build and deployment**: Source „Deploy from a branch“, Branch `main`, Ordner `/ (root)` → **Save**.
4. Nach etwa einer Minute ist das Spiel unter `https://DEIN-NAME.github.io/heuhaufen/` erreichbar.

### 3. Duell (1 gegen 1, einmalig)

Im Supabase-Projekt links **SQL Editor** öffnen, den kompletten Inhalt von `duell.sql` einfügen und **Run** klicken. Danach funktioniert auf der Startseite der Knopf **Duell starten**: Du spielst 5 Fragen, schickst den Link weiter, dein Gegner spielt dieselben Fragen – am Ende seht ihr Frage für Frage, wer seltener geantwortet hat.

### 4. Spielerprofile und Match-Historie (einmalig)

Im **SQL Editor** den kompletten Inhalt von `profil.sql` einfügen und **Run** klicken (erst nachdem `supabase.sql` und `duell.sql` gelaufen sind). Danach gibt es oben rechts den Knopf **Profil**: Siegquote, gewonnene Fragen, Ø Punkte, Nadeln, Tagesrätsel-Statistik, häufigste Gegner und die letzten 30 Duelle. Namen in der Bestenliste und im Duell führen zum Profil des Spielers; Profile lassen sich per Link teilen (`?spieler=…`).

### 5. Profile mit Anmeldung (einmalig)

Im **SQL Editor** den kompletten Inhalt von `konto.sql` einfügen und **Run** klicken (nach den anderen drei Skripten). Danach kann man oben rechts unter **Anmelden** ein Profil mit Name und Passwort erstellen und sich auf jedem Gerät damit anmelden. Die 3-Zeichen-Kürzel entfallen – Namen dürfen bis zu 10 Zeichen haben.

## Gut zu wissen

- **Profile:** Name (2–10 Zeichen) und Passwort. Mit Profil kann man sich auf jedem Gerät anmelden; Tagesrätsel und Duelle gibt es nur mit Profil, das freie Spiel geht auch ohne. Beim Erstellen werden die bisherigen Spiele auf dem Gerät übernommen. Nach 8 falschen Passwörtern ist ein Profil 15 Minuten gesperrt.
- **Ein Versuch pro Profil:** Jedes Profil kann das Tagesrätsel einmal am Tag spielen – egal auf welchem Gerät.
- **Punkte:** Die Datenbank berechnet die Punkte selbst aus den erreichten Stufen und lässt Ergebnisse nur wachsen, nie zurücksetzen oder nachträglich ändern. Ganz verhindern lässt sich Schummeln bei einem Spiel ohne Anmeldung aber nicht.
- **Namen:** kommen immer aus dem Profil, niemand kann sich als jemand anderes eintragen. Es gibt keinen Wortfilter. Einträge löschen kannst du im Supabase-Dashboard unter **Table Editor → scores** bzw. **duels**.
- **Passwort vergessen:** Es gibt keine E-Mail-Wiederherstellung. Im SQL Editor kannst du ein neues Passwort setzen: `update accounts set pw_hash = extensions.crypt('NEUES-PASSWORT', extensions.gen_salt('bf', 8)) where name_key = lower('NAME');`
- **Supabase-Gratisprojekte** werden nach längerer Zeit ohne Nutzung pausiert. Dann im Dashboard auf **Restore** klicken.
- **Ohne Supabase** (leere `config.js`) läuft das Spiel trotzdem – nur ohne Tagesrätsel-Bestenliste.
