{ pkgs, ... }:
{
  home.packages = [ pkgs.ollama ];

  systemd.user.services.ollama = {
    Unit = {
      Description = "Ollama LLM server";
      After = [ "network.target" ];
    };

    Service = {
      Environment = [
        "OLLAMA_HOST=127.0.0.1:11434"
        "OLLAMA_MODELS=%h/.local/share/ollama/models"
      ];
      ExecStart = "${pkgs.ollama}/bin/ollama serve";
      Restart = "always";
      RestartSec = 5;
    };

    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
