from vllm import LLM, SamplingParams
import os, time, pynvml
import math

prompts = [
    "Hello, my name is",
    "The president of the United States is",
]

sampling_params = SamplingParams(temperature=0.8, top_p=0.95)

def vllm_vram_gib():
    pynvml.nvmlInit()
    gpu = pynvml.nvmlDeviceGetHandleByIndex(0)
    mine = {os.getpid(), *map(int, os.popen(f"pgrep -P {os.getpid()} ").read().split())}
    return sum(p.usedGpuMemory for p in pynvml.nvmlDeviceGetComputeRunningProcesses(gpu) if p.pid in mine) / 2**30

def main():
    t = time.perf_counter()
    llm = LLM(model="Qwen/Qwen3-1.7B", gpu_memory_utilization=0.7)
    print(f"load: {time.perf_counter() - t:.1f}s, VRAM {vllm_vram_gib():.2f} GIB")
    
    block_size = llm.llm_engine.vllm_config.cache_config.block_size
    
    for prompt in prompts:
        t = time.perf_counter()
        output = llm.generate([prompt], sampling_params)[0]
        prompt_size = len(output.prompt_token_ids)
        gen_size = len(output.outputs[0].token_ids)
        kv_tokens = prompt_size + gen_size - 1
        blocks = math.ceil(kv_tokens / block_size)
        cached = output.num_cached_tokens or 0
        print(f"for prompt {output!r} it took {time.perf_counter() - t:.1f}s")
        print(f"Output: {output.outputs[0].text!r}\n")
        print(f"({blocks * block_size * 112 * 1024 / 2**20:.2f} MiB) {cached // block_size} blocks were reused from cache and the whole request consumed {blocks} blocks")


if __name__ == "__main__":
    main()
