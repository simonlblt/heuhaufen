# Heuhaufen

Das Ratespiel, bei dem seltene Antworten die meisten Punkte bringen – mit Tagesrätsel, Duellen, Profilen mit Profilbild, Level und Rangliste. Das freie Spiel geht ohne Anmeldung.

**Hier spielen:** https://simonlblt.github.io/heuhaufen/

## Dateien

| Datei | Wofür |
|---|---|
| `index.html` | Das komplette Spiel |
| `config.js` | Verbindung zur Datenbank (Supabase-Adresse und öffentlicher Schlüssel) |
| `setup.sql` | Das **eine** Einrichtungs-Skript für die Datenbank |

## Datenbank einrichten oder aktualisieren

Es gibt nur noch ein Skript: `setup.sql`. Es richtet alles ein, was die Seite braucht, und bringt eine bestehende Datenbank auf den neuesten Stand. Es kann beliebig oft laufen – Profile, Ergebnisse und Duelle bleiben erhalten.

1. `setup.sql` öffnen, alles markieren und kopieren.
2. Im Supabase-Projekt links **SQL Editor** öffnen, einfügen und **Run** klicken.
3. Es sollte „Success. No rows returned“ erscheinen.

Nach einem Update der Seite, das neue Funktionen bringt, einfach dieses Skript noch einmal laufen lassen. Solange das nicht passiert ist, läuft das Spiel weiter – nur die neuen Funktionen (z. B. Profilbilder, Level, Rangliste) melden, dass sie noch nicht eingerichtet sind.

## Zum ersten Mal einrichten (kostenlos)

### 1. Datenbank (Supabase)

1. Auf [supabase.com](https://supabase.com) kostenlos registrieren und **New project** anlegen (Name z. B. `heuhaufen`, Region **Frankfurt**). Das Datenbank-Passwort brauchst du für das Spiel nicht.
2. `setup.sql` wie oben beschrieben im **SQL Editor** ausführen.
3. Unter **Project Settings → API Keys** (bzw. **API**) diese zwei Werte kopieren:
   - die **Project URL** (sieht aus wie `https://abcdefghijkl.supabase.co`)
   - den **öffentlichen Schlüssel**: „publishable“ (`sb_publishable_…`) oder bei älteren Projekten „anon public“ (beginnt mit `eyJ`)
4. Beide Werte in `config.js` eintragen.

> Niemals den **secret**- bzw. **service_role**-Schlüssel verwenden oder weitergeben. Der öffentliche Schlüssel darf auf der Website stehen – die Datenbank lässt damit nur die Spiel-Aktionen zu.

### 2. Website (GitHub Pages)

1. Auf GitHub ein **öffentliches** Repository anlegen, z. B. `heuhaufen`.
2. `index.html`, `config.js` und `setup.sql` hochladen (gerne auch diese `README.md`).
3. **Settings → Pages → Build and deployment**: Source „Deploy from a branch“, Branch `main`, Ordner `/ (root)` → **Save**.
4. Nach etwa einer Minute ist das Spiel unter `https://DEIN-NAME.github.io/heuhaufen/` erreichbar.

## Was es gibt

- **Freies Spiel:** 200 Fragen, beliebig viele Runden, auch ohne Profil.
- **Tagesrätsel:** 5 Fragen, für alle dieselben, ein Versuch pro Profil und Tag, mit Bestenliste.
- **Duell (1 gegen 1):** Du spielst 5 Fragen und schickst einen Link weiter. Pro Frage gewinnt die seltenere Antwort, gleiche Antworten zählen für keinen.
- **Profile:** Name (2–10 Zeichen) und Passwort, Anmeldung auf jedem Gerät. Mit Profilbild (Symbol oder eigenes Foto), Statistiken, Match-Historie, Abzeichen und Link zum Teilen (`?spieler=…`).
- **Level und Rangliste:** Jede Runde bringt XP. Tagesrätsel und Duell zählen mit vollen Punkten, das freie Spiel mit den halben. Dazu gibt es 100 XP je Duellsieg und 150 XP je Tagessieg (sobald der Tag vorbei ist). Level 2 gibt es ab 200 XP, Level 3 ab 500, Level 5 ab 1.400, Level 10 ab 5.400.
- **Ton und Design:** Oben rechts lassen sich die Töne ausschalten und das helle oder dunkle Design wählen.

## Gut zu wissen

- **Profilbilder:** Vom Foto wird im Browser nur ein kleiner runder Ausschnitt (192 × 192 Pixel) erzeugt und gespeichert; das Original verlässt das Gerät nicht. Profilbilder sind für alle sichtbar und werden nicht geprüft. Ein Bild entfernen kannst du im SQL Editor: `update accounts set avatar = null where name_key = lower('NAME');`
- **Ein Versuch pro Profil:** Jedes Profil kann das Tagesrätsel einmal am Tag spielen – egal auf welchem Gerät.
- **Punkte:** Die Datenbank berechnet Punkte und XP selbst aus den erreichten Stufen und lässt Ergebnisse nur wachsen. Im freien Spiel zählen höchstens eine Runde alle 20 Sekunden und 60 Runden pro Tag. Ganz verhindern lässt sich Schummeln bei so einem Spiel aber nicht.
- **Namen:** kommen immer aus dem Profil, niemand kann sich als jemand anderes eintragen. Es gibt keinen Wortfilter. Einträge löschen kannst du im Supabase-Dashboard unter **Table Editor → scores**, **duels** bzw. **accounts**.
- **Passwort vergessen:** Es gibt keine E-Mail-Wiederherstellung. Im SQL Editor kannst du ein neues Passwort setzen: `update accounts set pw_hash = extensions.crypt('NEUES-PASSWORT', extensions.gen_salt('bf', 8)) where name_key = lower('NAME');`
- **Supabase-Gratisprojekte** werden nach längerer Zeit ohne Nutzung pausiert. Dann im Dashboard auf **Restore** klicken.
- **Ohne Supabase** (leere `config.js`) läuft das freie Spiel trotzdem – nur ohne Tagesrätsel, Duelle und Profile.
