# Heuhaufen

Das Ratespiel, bei dem seltene Antworten die meisten Punkte bringen – mit Tagesrätsel und Bestenliste. Spielbar ohne Anmeldung.

**Hier spielen:** https://simonlblt.github.io/heuhaufen/

## Dateien

| Datei | Wofür |
|---|---|
| `index.html` | Das komplette Spiel |
| `config.js` | Verbindung zur Bestenliste (Supabase-Adresse und öffentlicher Schlüssel) |
| `supabase.sql` | Einrichtungs-Skript für die Datenbank |

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

## Gut zu wissen

- **Ein Versuch pro Gerät:** Ohne Anmeldung merkt sich das Spiel im Browser, dass heute schon gespielt wurde. Wer den Browser-Speicher löscht oder ein anderes Gerät nimmt, kann nochmal spielen.
- **Punkte:** Die Datenbank berechnet die Punkte selbst aus den erreichten Stufen und lässt Ergebnisse nur wachsen, nie zurücksetzen oder nachträglich ändern. Ganz verhindern lässt sich Schummeln bei einem Spiel ohne Anmeldung aber nicht.
- **Kürzel:** 3 Zeichen (A–Z, 0–9, Ä, Ö, Ü), einmal pro Tagesergebnis. Es gibt keinen Wortfilter. Einträge löschen kannst du im Supabase-Dashboard unter **Table Editor → scores**.
- **Supabase-Gratisprojekte** werden nach längerer Zeit ohne Nutzung pausiert. Dann im Dashboard auf **Restore** klicken.
- **Ohne Supabase** (leere `config.js`) läuft das Spiel trotzdem – nur ohne Tagesrätsel-Bestenliste.
