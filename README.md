# tg-logger

Simple telegram logger which uses telegram-cli and sqlite DBMS.

## Building

Nim compiler and telegram-cli are required. Run `make` to build the project.

## Configuration

Logger uses telegram-cli configuration from working directory.
Run ```TELEGRAM_HOME=`pwd` telegram-cli``` to configure telegram-cli.

## Queries

- `tglogger chats [<filter>]` — display chats
- `tglogger query last <count> [<chat id>]` — display last `count` messages from `chat id`.
- `tglogger query from <time> [<count>]` — display `count` messages from `time`.
- `tglogger query search <text>` — search messages with `text`.
