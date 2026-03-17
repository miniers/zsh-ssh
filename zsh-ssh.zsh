#!/usr/bin/env zsh

# Better completion for ssh in Zsh.
# https://github.com/sunlei/zsh-ssh
# v0.0.7
# Copyright (c) 2020 Sunlei <guizaicn@gmail.com>

setopt no_beep # don't beep
zstyle ':completion:*:ssh:*' hosts off # disable built-in hosts completion

SSH_CONFIG_FILE="${SSH_CONFIG_FILE:-$HOME/.ssh/config}"
FZF_SSH_LIST_KEY="${FZF_SSH_LIST_KEY:-^G}"

# Parse the file and handle the include directive.
_parse_config_file() {
  # Enable PCRE matching and handle local options
  setopt localoptions rematchpcre
  unsetopt nomatch

  # Resolve the full path of the input config file
  local config_file_path=$(realpath "$1")

  # Read the file line by line
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Match lines starting with 'Include'
    if [[ $line =~ ^[Ii]nclude[[:space:]=]+(.*) ]] && (( $#match > 0 )); then
      # Split the rest of the line into individual paths
      local include_paths=(${(z)match[1]})

      for raw_path in "${include_paths[@]}"; do
        # Expand ~ and environment variables in the path
        eval "local expanded=\${(e)raw_path}"
        # local expanded="${raw_path/#~/$HOME}"

        # If path is relative, resolve it relative to the current config file
        if [[ "$expanded" != /* ]]; then
          if [[ "$expanded" == ~* ]]; then
            expanded="${expanded/#\~/$HOME}"
          else
            expanded="$(dirname "$config_file_path")/$expanded"
          fi
        fi

        # Expand wildcards (e.g. *.conf) and loop over each matched file
        for include_file_path in $~expanded; do
          if [[ -f "$include_file_path" ]]; then
            # Separate includes with a blank line (for readability)
            echo ""
            # Recursively parse included files
            _parse_config_file "$include_file_path"
          fi
        done
      done
    else
      # Print normal (non-Include) lines
      echo "$line"
    fi
  done < "$config_file_path"
}

_ssh_host_list() {
  local ssh_config host_list

  ssh_config=$(_parse_config_file $SSH_CONFIG_FILE)
  ssh_config=$(echo $ssh_config | command grep -v -E "^\s*#[^_]")
  # Ensure blank line before each Host/Match block for AWK paragraph mode (RS="")
  ssh_config=$(echo $ssh_config | command awk '/^[[:space:]]*[Hh]ost[[:space:]]|^[[:space:]]*[Mm]atch[[:space:]]/{print ""} {print}')

  host_list=$(echo $ssh_config | command awk '
    function join(array, start, end, sep, result, i) {
      # https://www.gnu.org/software/gawk/manual/html_node/Join-Function.html
      if (sep == "")
        sep = " "
      else if (sep == SUBSEP) # magic value
        sep = ""
      result = array[start]
      for (i = start + 1; i <= end; i++)
        result = result sep array[i]
      return result
    }

    function parse_line(line) {
      gsub(/^[[:space:]]+/, "", line)
      n = split(line, line_array, /[[:space:]]*=[[:space:]]*|[[:space:]]+/)

      key = line_array[1]
      value = join(line_array, 2, n)

      return key "#-#" value
    }

    function starts_or_ends_with_star(str) {
        start_char = substr(str, 1, 1)
        end_char = substr(str, length(str), 1)

        return start_char == "*" || end_char == "*" || start_char == "!"
    }

    BEGIN {
      IGNORECASE = 1
      FS="\n"
      RS=""
    }
    {
      match_directive = ""

      # Use spaces to ensure the column command maintains the correct number of columns.
      #   - user
      #   - desc_formated

      user = " "
      host_name = ""
      alias = ""
      aliases = ""
      desc = ""
      desc_formated = " "
      cmd = ""

      for (line_num = 1; line_num <= NF; ++line_num) {
        line = parse_line($line_num)

        split(line, tmp, "#-#")

        key = tolower(tmp[1])
        value = tmp[2]

        if (key == "match") { match_directive = value }

        if (key == "host") { aliases = value }
        if (key == "user") { user = value }
        if (key == "hostname") { host_name = value }
        if (key == "#_desc") { desc = value }
        if (key == "#_cmd") {
          cmd_value = tolower(value)
          if (cmd_value == "ssh" || cmd_value == "sshrc") {
            cmd = cmd_value
          }
        }
      }

      if (desc) {
        desc_formated = sprintf("[\033[00;34m%s\033[0m]", desc)
      }

      n_aliases = split(aliases, alias_list, " ")
      for (i = 1; i <= n_aliases; i++) {
        alias = alias_list[i]
        effective_hostname = host_name ? host_name : alias

        if (!(effective_hostname && !starts_or_ends_with_star(effective_hostname)) || !(alias && !starts_or_ends_with_star(alias)) || match_directive) {
          continue
        }

        # Per-alias aggregation: each field uses first-non-empty wins
        # Extra rule: explicit HostName takes precedence over fallback value
        if (!(alias in alias_hn)) {
          alias_hn[alias] = effective_hostname
          alias_user[alias] = user
          alias_desc[alias] = desc_formated
          alias_cmd[alias] = cmd
          if (host_name) alias_explicit_hn[alias] = 1
        } else {
          if (host_name && !alias_explicit_hn[alias]) {
            alias_hn[alias] = host_name
            alias_explicit_hn[alias] = 1
          }
          if (user != " " && alias_user[alias] == " ") {
            alias_user[alias] = user
          }
          if (desc_formated != " " && alias_desc[alias] == " ") {
            alias_desc[alias] = desc_formated
          }
          if (cmd != "" && alias_cmd[alias] == "") {
            alias_cmd[alias] = cmd
          }
        }
      }
    }
    END {
      for (a in alias_hn) {
        printf "%s|->|%s|%s|%s|%s\n", a, alias_hn[a], alias_user[a], alias_desc[a], alias_cmd[a]
      }
    }
  ')

  for arg in "$@"; do
    case $arg in
    -*) shift;;
    *) break;;
    esac
  done

  if [[ -n "$1" ]]; then
    host_list=$(command grep -i "$1" <<< "$host_list")
  fi
  host_list=$(printf "%s\n" "$host_list" | command sort -u)

  echo $host_list
}


_fzf_list_generator() {
  local host_list

  if [ -n "$1" ]; then
    host_list="$1"
  else
    host_list=$(_ssh_host_list)
  fi

  # Output two tab-separated columns:
  #   1) raw machine-readable record
  #   2) aligned display text for fzf
  printf '%s\n' "$host_list" | command awk -F'\\|' '
    {
      raw = $0
      display = sprintf("%-24s %-2s %-20s %-12s %-20s %-6s", $1, $2, $3, $4, $5, $6)
      printf "%s\t%s\n", raw, display
    }
  '
}

_set_lbuffer() {
  local result selected_host connect_cmd is_fzf_result fallback_cmd selected_cmd raw_result
  result="$1"
  is_fzf_result="$2"
  fallback_cmd="${3:-ssh}"

  if [ "$is_fzf_result" = false ] ; then
    selected_host=$(cut -f 1 -d "|" <<< "$result")
    selected_cmd=$(cut -f 5 -d "|" <<< "$result")
  else
    raw_result=${result%%$'\t'*}
    if [[ "$raw_result" == *"|"* ]]; then
      selected_host=$(cut -f 1 -d "|" <<< "$raw_result")
      selected_cmd=$(cut -f 5 -d "|" <<< "$raw_result")
    else
      selected_host=$(cut -f 1 <<< "$result")
      selected_cmd=$(cut -f 6 <<< "$result")
    fi
  fi

  if [[ "$selected_cmd" != "ssh" && "$selected_cmd" != "sshrc" ]]; then
    selected_cmd="$fallback_cmd"
  fi

  connect_cmd="${selected_cmd} ${selected_host}"

  LBUFFER="$connect_cmd"
}

_fzf_pick_ssh_host() {
  local host_list prompt query table_header
  host_list="$1"
  prompt="${2:-SSH Remote > }"
  query="$3"
  table_header='Alias                    -> Hostname             User         Desc                 Conn'

  _fzf_list_generator "$host_list" | fzf \
    --height 40% \
    --ansi \
    --border \
    --cycle \
    --info=inline \
    --header="$table_header" \
    --reverse \
    --prompt="$prompt" \
    --query="$query" \
    --delimiter=$'\t' \
    --with-nth=2 \
    --no-separator \
    --bind 'shift-tab:up,tab:down,bspace:backward-delete-char/eof' \
    --preview 'raw=$(cut -f 1 <<< {}); target=${raw%%|*}; desc=$(cut -d "|" -f 5 <<< "$raw"); if [[ -n "${desc// }" ]]; then printf "Desc  %b\n\n" "$desc"; fi; ssh -T -G "$target" | grep -i -E "^User |^HostName |^Port |^ControlMaster |^ForwardAgent |^LocalForward |^RemoteForward |^ProxyCommand |^ProxyJump " | column -t' \
    --preview-window=right:40% \
    --expect=alt-enter,enter
}

fzf_open_ssh_list() {
  local result key selection host_list

  host_list=$(_ssh_host_list)
  if [[ -z "$host_list" ]]; then
    zle reset-prompt
    return
  fi

  result=$(_fzf_pick_ssh_host "$host_list" 'Server List > ' '')
  if [[ -z "$result" ]]; then
    zle reset-prompt
    return
  fi

  key=${result%%$'\n'*}
  if [[ "$key" == "$result" ]]; then
    selection="$result"
    key=""
  else
    selection=${result#*$'\n'}
  fi

  if [[ -n "$selection" ]]; then
    _set_lbuffer "$selection" true ssh
    if [[ "$key" == "alt-enter" ]]; then
      zle reset-prompt
    else
      zle accept-line
    fi
  fi

  if [[ "$key" != "alt-enter" ]]; then
    zle reset-prompt
  fi
}

fzf_complete_ssh() {
  local tokens cmd result key selection
  setopt localoptions noshwordsplit noksh_arrays noposixbuiltins

  tokens=(${(z)LBUFFER})
  cmd=${tokens[1]}

  if [[ "$LBUFFER" =~ "^ *(ssh|sshrc)$" ]]; then
    zle ${fzf_ssh_default_completion:-expand-or-complete}
  elif [[ "$cmd" == "ssh" || "$cmd" == "sshrc" ]]; then
    result=$(_ssh_host_list ${tokens[2, -1]})
    fuzzy_input="${LBUFFER#"$tokens[1] "}"

    if [ -z "$result" ]; then
      # When host parameters exist, don't fall back to default completion to avoid slow hosts enumeration
      if [[ -z "${tokens[2]}" || "${tokens[-1]}" == -* ]]; then
        zle ${fzf_ssh_default_completion:-expand-or-complete}
      fi
      return
    fi

    if [ $(echo $result | wc -l) -eq 1 ]; then
      _set_lbuffer "$result" false "$cmd"
      zle reset-prompt
      # zle redisplay
      return
    fi

    result=$(_fzf_pick_ssh_host "$result" 'SSH Remote > ' "$fuzzy_input")

    if [ -n "$result" ]; then
      key=${result%%$'\n'*}
      if [[ "$key" == "$result" ]]; then
        selection="$result"
        key=""
      else
        selection=${result#*$'\n'}
      fi

      if [ -n "$selection" ]; then
        _set_lbuffer "$selection" true $cmd
        if [[ "$key" == "alt-enter" ]]; then
          zle reset-prompt
        else
          zle accept-line
        fi
      fi
    fi

    # Only reset prompt if not already done for alt-enter
    if [[ "$key" != "alt-enter" ]]; then
      zle reset-prompt
      # zle redisplay
    fi

  # Fall back to default completion
  else
    zle ${fzf_ssh_default_completion:-expand-or-complete}
  fi
}


[ -z "$fzf_ssh_default_completion" ] && {
  binding=$(bindkey '^I')
  [[ $binding =~ 'undefined-key' ]] || fzf_ssh_default_completion=$binding[(s: :w)2]
  unset binding
}


zle -N fzf_complete_ssh
bindkey '^I' fzf_complete_ssh
zle -N fzf_open_ssh_list
bindkey "$FZF_SSH_LIST_KEY" fzf_open_ssh_list

# vim: set ft=zsh sw=2 ts=2 et
