# PiComms
komunikator pikczu

Prosty, prywatny czat tekstowy na iOS dla dwóch osób. Zamiast serwera aplikacja używa **Google Drive** jako bazy danych: rozmowa to wspólny folder na Drive, udostępniony drugiej osobie.

## Funkcje

- logowanie kontem Google,
- czat tekstowy 1 na 1 (nowe wiadomości sprawdzane co 3 s, gdy aplikacja jest otwarta),
- ustawianie **nazwy użytkownika** i **zdjęcia profilowego** (dotknij swojego avatara w prawym górnym rogu),
- lokalna pamięć podręczna: historia jest widoczna także bez internetu, a niewysłane wiadomości można wysłać ponownie jednym dotknięciem.

## Jak dane są zapisane na Google Drive

```
PiComms/                         ← folder na Drive osoby, która założyła czat, udostępniony drugiej osobie
├── profile-ty@gmail.com.json    ← nazwa + zdjęcie (JPEG 256×256 w base64), jeden plik na osobę
├── profile-ona@gmail.com.json
├── msg-2026-09-24T20:53:01.123Z-<uuid>.json   ← każda wiadomość to osobny plik
└── ...
```

Każda wiadomość to osobny plik, więc dwie osoby piszące jednocześnie nigdy nie nadpiszą sobie danych. Pliki są oznaczone polami `properties` (`type=message` / `type=profile`), dzięki czemu aplikacja pobiera tylko nowe wiadomości.

## Konfiguracja (jednorazowo, ok. 15 minut)

Potrzebujesz Maca z Xcode 15 lub nowszym oraz konta Google.

### 1. Google Cloud Console

1. Wejdź na <https://console.cloud.google.com/> i utwórz nowy projekt, np. „PiComms”.
2. **APIs & Services → Library** → wyszukaj **Google Drive API** → **Enable**.
3. **Google Auth Platform** (dawniej „OAuth consent screen”):
   - typ użytkowników: **External**, nazwa aplikacji: PiComms, e-mail kontaktowy: Twój,
   - **Data Access → Add or remove scopes** → dodaj `https://www.googleapis.com/auth/drive`,
   - **Audience → Test users** → dodaj **oba** adresy Gmail (Twój i dziewczyny).
4. **Credentials → Create credentials → OAuth client ID**:
   - typ aplikacji: **iOS**,
   - Bundle ID: `pl.pikczu.PiComms` (albo Twój, jeśli go zmienisz w Xcode).
5. Skopiuj **Client ID** (wygląda jak `1234567890-abc...apps.googleusercontent.com`).

### 2. Aplikacja

1. Otwórz `PiComms/Config.swift` i wklej Client ID:
   ```swift
   static let googleClientID = "1234567890-abc....apps.googleusercontent.com"
   ```
2. Otwórz `PiComms.xcodeproj` w Xcode.
3. Zaznacz target **PiComms → Signing & Capabilities → Team** i wybierz swoje konto Apple.
   Jeśli Xcode zgłosi, że Bundle ID jest zajęty, zmień go (np. `pl.twojenazwisko.PiComms`) – i wpisz ten sam w kliencie iOS w Google Cloud.
4. Podłącz iPhone’a, wybierz go jako cel i naciśnij **Run** (⌘R). Powtórz dla telefonu dziewczyny.

> Z darmowym kontem Apple aplikacja zainstalowana z Xcode działa 7 dni, potem trzeba ją zainstalować ponownie. Z płatnym kontem Apple Developer możesz ją rozesłać przez TestFlight.

## Pierwsze uruchomienie

1. **Ty**: zaloguj się przez Google → wpisz adres Gmail dziewczyny → **Utwórz czat i wyślij zaproszenie**.
   Na Twoim Drive powstanie folder `PiComms`, udostępniony jej z prawem edycji.
2. **Ona**: zaloguje się swoim kontem Google – aplikacja sama znajdzie udostępniony folder
   (albo niech dotknie „Sprawdź, czy dostałem zaproszenie”).
3. Każde z Was ustawia swoją nazwę i zdjęcie, dotykając avatara w prawym górnym rogu czatu.

## Warto wiedzieć

- **Tryb testowy Google**: dopóki aplikacja jest w trybie „Testing” w Google Cloud, Google unieważnia logowanie co 7 dni – aplikacja wtedy po prostu poprosi o ponowne zalogowanie. Żeby tego uniknąć, możesz w **Audience** kliknąć **Publish app**; przy logowaniu pojawi się wtedy ostrzeżenie „Google nie zweryfikował tej aplikacji” (Zaawansowane → Przejdź do PiComms), co przy prywatnym użyciu jest w porządku.
- **Uprawnienia**: aplikacja prosi o pełny dostęp do Drive, bo tylko wtedy druga osoba może czytać pliki utworzone przez Ciebie we wspólnym folderze. Aplikacja korzysta wyłącznie z folderu `PiComms`, a tokeny logowania trzyma w Keychain telefonu.
- **Powiadomienia push** nie są obsługiwane – Google Drive nie potrafi „obudzić” aplikacji. Nowe wiadomości pojawiają się, gdy aplikacja jest otwarta.

## Struktura kodu

| Plik | Opis |
| --- | --- |
| `Config.swift` | Client ID Google i ustawienia |
| `GoogleAuth.swift` | logowanie OAuth 2.0 + PKCE, odświeżanie tokenów, Keychain |
| `DriveClient.swift` | minimalny klient REST Google Drive API v3 |
| `ChatStore.swift` | logika czatu: wyszukiwanie/zakładanie folderu, synchronizacja, wysyłanie, profile, cache |
| `ChatView.swift` | ekran rozmowy |
| `ProfileView.swift` | nazwa użytkownika i zdjęcie profilowe |
| `SetupChatView.swift` | zakładanie czatu / zaproszenie |
| `SignInView.swift` | ekran logowania |
