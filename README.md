# SchulUmfrage

Zweiteilige Mentimeter-ähnliche Webapp für Unterricht:

- `teacher.html` – geschützter Lehrerbereich
- `student.html` – Schüler-Link
- `schema.sql` – Supabase-Datenbank/RLS

## Architektur
GitHub Pages hostet die HTML-Dateien. Supabase übernimmt Auth, Datenbank, Realtime und Storage. Es gibt absichtlich keinen eigenen Server und kein Local Storage als Datenquelle.

## Supabase
Projekt: `SchulQuiz` (`mqtcwiiawmuxrpkjfrfc`)

1. SQL aus `schema.sql` ausführen.
2. Im Supabase Dashboard unter Authentication einen Lehrer-Account anlegen.
3. Storage: Bucket `survey-media` anlegen und nur authentifizierten Lehrern Uploads erlauben. Für die endgültige Version sollte die Storage-RLS auf den Lehrerordner `${auth.uid()}` begrenzt sein.
4. Realtime für `sessions`, `participants` und `responses` aktivieren.
5. GitHub Pages aktivieren.

## Enthaltene Folientypen
Multiple-Choice, Wortwolke/kurze Texteingabe, offene Frage, Skala, Ranking-Grundstruktur, Q&A-Grundstruktur, Pin-Grundstruktur.

## Medien
Bilder, Audio und Video werden in Supabase Storage gespeichert. Die Umfrage speichert nur die öffentliche Medien-URL, sodass Medien von anderen PCs geladen werden können.

## Wichtiger Hinweis
Die aktuelle Version ist ein funktionsfähiger MVP. Für den produktiven Einsatz sollten als nächstes insbesondere die öffentliche Session-Abfrage, Teilnehmer-Sicherheit, echte Ranking-/Pin-/Wortwolkenvisualisierung, QR-Code im Lehrerbereich, Präsentationsansicht und Quiz/Punktevergabe weiter ausgebaut werden.
