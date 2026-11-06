# Jetson Ollama setup guide

This guide walks you through the setup of ollama on the Jetson Orin Nano's.

## Setting up Ollama

We can use a system service approach for Ollama so this is pulling it directly from Ollama's website and installing it as per their install instructions

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Once Ollama has been installed run the setup script to configure the service environment options.

```bash
sudo bash setup-ollama-jetson.sh
```

This script sets up the environment variables in the service, builds the required environment and service overrides and then restars the relevant services to enable ollama to work effectively on the jetson. It checks to see whether or not ollama can detect the GPU on the Jetson as well.

The script has options for setup with sensible defaults and these are not normally required to change, but should they need to be changed they can be. The options are as followz:

| Option | Flag | description | default |
|------- | ---- | ------- | -------- |
|Context length | --ctx N | This sets up the context length in tokens for ollama | 32768 |
|Keep alive | --keep-alive VAL | This is the amount of time a model is kept alive for, -1 is forever | 5m |
|Host address | --host ADDR:PORT | This is the bind address for the ollama instance | 127.0.0.1:11434 |
|Model directory | --models-dir | Sets the model store location should the differ from Ollamas default | unchanged |
|KV Cache | --kv-cache | Sets up the K/V cache quantisation options for ollama, this quantises the model to help it fit in the RAM on the jetson (f16, q8_0, q4_0) | q4_0 |
|Disable Flash Attention | --no-flash-attn | Using this flag sets up ollama with flash attention disabled, this is enabled by default and helps ollama manage RAM with growing context | |
|Dry run | --dry-run | Prints the override settings for ollama, but doesn't set them so you can check things are as they're supposed to be before running | |

Anything that has been setup by the script can be modified by running 

```bash
sudo systemctl edit ollama.service
```

Once this has been setup you can run a small model from ollama to test with, for example

```bash
ollama run gemma3:270m "Hello" --verbose
```
This pulls the gemma3:270m model from ollama assuming it hasn't already been pulled, runs the prompt "hello" through. The verbose option here gives information about how long it too to run the various stages including model loading, prompt evaluation and response token creation.

## Pulling LLMs

Models can be browsed at [ollama's models library](https://ollama.com/library).

Once you've identified a model you can pull it by referencing it's name and tag for example, to pull the gemma4:e2b model - where gemma4 is the model name, and e2b is the tag - run:
```bash
ollama pull gemma4:e2b
```

If you don't specify a tag it will pull the model that is labelled as latest, in gemma4's case this is the e4b model.

## Running a model

You can chat with a model in the terminal using Ollama's built in interface by running:
```bash
ollama run gemma3:270m
```
