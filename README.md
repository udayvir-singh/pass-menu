# Introduction

`pass-menu` is a command-line utility that provides a general
interface to password store that works well with any command that
accepts stdin. ie `fzf`, `dmenu`, `rofi`, and even `grep`.

## Features

- :penguin: Follows the UNIX philosophy, allowing easy integration with any CLI tool.
- :briefcase: Written entirely in Bash, ensuring maximum portability.
- :four_leaf_clover: Supports autofill and clipboard functionality on both Wayland and X11.
- :floppy_disk: Utilizes a custom LR parser for passfiles that supports:
  - :dart: Fields composed of key-value pairs separated by colons.
  - :closed_lock_with_key: OTP code generation from otpauth URIs.
  - :minidisc: Scriptable actions for automating passfiles.

# Dependencies

- [bash](https://www.gnu.org/software/bash)
- [find](https://www.gnu.org/software/findutils)
- [pass](https://git.zx2c4.com/password-store)
- [libnotify](https://gitlab.gnome.org/GNOME/libnotify) (optional for notification support)
- [oathtool](https://www.nongnu.org/oath-toolkit) (optional for generating OTP codes)
- X11
  - [xclip](https://github.com/astrand/xclip) (optional for clipboard support)
  - [xdotool](https://github.com/jordansissel/xdotool) (optional for autofill support)
- Wayland
  - [wl-clipboard](https://github.com/bugaevc/wl-clipboard) (optional for clipboard support)
  - [wtype](https://github.com/atx/wtype) (optional for autofill support)

# Installation

```bash
$ git clone https://github.com/udayvir-singh/pass-menu.git

$ cd pass-menu

# To install pass-menu for the current user:
$ make install

# To install pass-menu globally for all users:
$ sudo make PREFIX=/usr install
```

Refer to `make help` for more details about installation.

# Usage

```bash
pass-menu [OPTIONS] -- COMMAND [ARGS]
```

| Option                                    | Description                                             |
|-------------------------------------------|---------------------------------------------------------|
| `-t`, `--type`                            | Type the output.                                        |
| `-c`, `--clip`                            | Copy the output to the clipboard.                       |
| `-p`, `--print`                           | Print the output to stdout.                             |
| `-f`, <code>--filename=**NAME**</code>    | Manually set the password store filename.               |
| `-k`, <code>--key=**NAME**</code>         | Manually set the password store key.                    |
| `-l`, <code>--log=**TYPE**</code>         | Set the logger type. (options: compact, human, notify)  |
| `-F`, <code>--prompt-flag=**FLAG**</code> | Flag passed to `COMMAND` for prompting the user.        |
| <code>--file-prompt=**PROMPT**</code>     | Prompt message when choosing a password store filename. |
| <code>--key-prompt=**PROMPT**</code>      | Prompt message when choosing a password store key.      |
| <code>--mode-prompt=**PROMPT**</code>     | Prompt message when choosing pass-menu mode.            |
| `-h`, `--help`                            | Print the help message and exit.                        |

Refer to `pass-menu --help` or `man pass-menu` for more details.

## Examples

The following examples are taken from `man pass-menu`:

### FZF (Fuzzy Finder)

```bash
# Basic usage:
$ pass-menu -- fzf

# Copy a field from a password store file:
$ pass-menu --clip -- fzf

# Enable interactive input prompt:
$ pass-menu -Fprompt -- fzf
$ pass-menu --prompt-flag="--prompt" -- fzf
```

### DMenu (Dynamic Menu)

```bash
# Basic usage:
$ pass-menu -- dmenu

# Type a field from a password store file:
$ pass-menu --type -- dmenu

# Enable interactive input prompt:
$ pass-menu -Fp -- dmenu
$ pass-menu --prompt-flag="-p" -- dmenu
```

### Rofi

```bash
# Basic usage:
$ pass-menu -- rofi -dmenu

# Type a field from a password store file:
$ pass-menu --type -- rofi -dmenu

# Enable interactive input prompt:
$ pass-menu -Fp -- rofi -dmenu
$ pass-menu --prompt-flag="-p" -- rofi -dmenu
```

### Non-Interactive

```bash
# Basic usage:
$ pass-menu --print --filename "Github" --key "Password"

# The above example also works with actions:
$ pass-menu --filename "Github" --key "((Autofill))"
```

# Passfile Syntax

`pass-menu` uses its own custom parser for parsing passfiles.
This section provides a brief overview of the passfile syntax.

For complete details, refer to the `PASSFILE SYNTAX` section in `man pass-menu`.

Here's an example passfile:

```
correct-horse-battery-staple
---
Username: hello-world
Email:    "${Username}@example.com"

otpauth://totp/hello@example.com?secret=MV4AU&issuer=Example

action(Autofill) :type Username :tab :type Password :clip OTP
```

The following sections provide more details about each component of the syntax.

## Password Line

```
correct-horse-battery-staple
```

The first line of the passfile is called the password line if it isn't
a field, an otpauth URI, or an action. The password line is treated the
same as a field with `Password` as the key.

The above example can also be converted to a field.
Hence, the following is the same as the above example:

```
Password: correct-horse-battery-staple
```

## Field

```
Username: hello-world
Email:    "${Username}@example.com"
```

A key-value pair separated by a colon is regarded as a field.

The key must only contain the following characters `[-_a-zA-Z0-9<space><tab>]`
and cannot be `OTP` as it's reserved for otpauth URIs.

The value can either be raw text (as in the `Username` field)
or a double quoted string (as in the `Email` field).

The string value can contain escape characters (`\\`, `\$`, and `\"`)
and POSIX style variables with references to a field (for example: `${Username}`).

Any leading or trailing whitespace is trimmed from raw text in field values.
If you want the whitespace, then the value should be quoted in a string.

## Otpauth URI

```
otpauth://totp/hello@example.com?secret=MV4AU&issuer=Example
```

The above is an example of an otpauth URI for `example.com`.

The otpauth URI must follow the format described by
[Google Authenticator](https://github.com/google/google-authenticator/wiki/Key-Uri-Format),
and the label in the otpauth URIs must be unique.

## Action

```
action(Autofill) :type Username :tab :type Password :clip OTP
```

The above is an example of an action that autofills `Username` and
`Password` in a GUI form and copies the `OTP` to the clipboard.

Actions enable automation within `pass-menu`, performing tasks
such as autofilling forms, updating passwords, etc.

The action body consists of commands with an optional argument.
The argument can be either a single word or a string value.

The following table explains all of the action commands:

| Command        | Description                                                                    |
|----------------|--------------------------------------------------------------------------------|
| `:tab`         | Press the tab key.                                                             |
| `:enter`       | Press the enter key.                                                           |
| `:type <REF>`  | Type the field or OTP that matches the given reference.                        |
| `:clip <REF>`  | Copy the field or OTP that matches the given reference to the clipboard.       |
| `:run <REFS>`  | Execute the comma separated list of actions that match the given reference.    |
| `:log <STR>`   | Log the message with the given string.                                         |
| `:sleep <DUR>` | Delay for the given amount of time, accepts same arguments as `sleep` command. |
| `:exec <CMD>`  | Execute the given bash command with `$1` set to the current filename.          |
