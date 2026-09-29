import time
import json
import openai

def main():

    with open("bench/system_prompt.txt", "r") as f:
        system_prompt = f.read()

    with open("bench/user_prompt.txt", "r") as f:
        user_prompts = json.load(f)

    prompts = [
        system_prompt + "\n\n" + user_prompt for user_prompt in user_prompts
    ]

    client = openai.OpenAI(
        base_url="http://localhost:8000/v1",
        api_key="not-needed",
    )

    for prompt in prompts:
        t = time.perf_counter()

        client.chat.completions.create(
            model="Qwen/Qwen3-1.7B",
            messages=[
                {"role": "user", "content": prompt},
            ],
            stream=False,
            max_tokens=50,
        )

        print(f"That response took {time.perf_counter() - t:.1f}s")



if __name__ == "__main__":
    main()
