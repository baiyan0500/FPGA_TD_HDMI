import os
import sys
import argparse
from PIL import Image

MAX_WIDTH = 1024
MAX_HEIGHT = 2047


def prepare_image(img, target_width, target_height, keep_size=False):
    """转为 RGB；keep_size 时只做上限内的等比缩放，否则缩放到指定尺寸。"""
    img_rgb = img.convert('RGB')

    if keep_size:
        width, height = img_rgb.size
        scale = min(1.0, MAX_WIDTH / width, MAX_HEIGHT / height)
        if scale < 1.0:
            new_size = (max(1, int(width * scale)), max(1, int(height * scale)))
            print(f"  [缩放] {width}x{height} -> {new_size[0]}x{new_size[1]}（超出固件上限）")
            img_rgb = img_rgb.resize(new_size, Image.Resampling.LANCZOS)
        return img_rgb

    return img_rgb.resize((target_width, target_height), Image.Resampling.LANCZOS)


def convert_single_file(input_path, output_path, target_width=640, target_height=480, keep_size=False):
    """
    将单张图片转换为无压缩 24-bit BMP。
    keep_size=True 时保持原尺寸（仅在不超 1024x2047 时），否则缩放到 target 尺寸。
    """
    if not os.path.exists(input_path):
        print(f"[错误] 找不到输入文件: {input_path}")
        return False

    try:
        with Image.open(input_path) as img:
            img_out = prepare_image(img, target_width, target_height, keep_size)

            if not output_path.lower().endswith('.bmp'):
                output_path += '.bmp'

            img_out.save(output_path, 'BMP')
            print(f"[成功] 转换完成: {input_path} -> {output_path} ({img_out.size[0]}x{img_out.size[1]})")
            return True
    except Exception as e:
        print(f"[失败] 转换 {input_path} 时发生错误: {e}")
        return False


def clear_old_bmp(output_dir):
    """
    清空上一次批量转换留下的 BMP。
    否则输入图片数量变少时，旧输出会继续留在 output_bmp 并被同步到 TF 卡。
    """
    removed = 0
    for name in os.listdir(output_dir):
        if name.lower().endswith('.bmp'):
            try:
                os.remove(os.path.join(output_dir, name))
                removed += 1
            except OSError as e:
                print(f"[警告] 无法删除旧输出 {name}: {e}")
    if removed:
        print(f"已清理 {removed} 个上一次生成的 BMP。")


def convert_to_bmp(input_dir, output_dir, target_width=640, target_height=480, keep_size=False):
    """
    批量转换为无压缩 24-bit BMP。
    keep_size=True 时保持每张图原尺寸（超过 1024x2047 时等比缩小）。
    """
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    clear_old_bmp(output_dir)

    supported_formats = ('.png', '.jpg', '.jpeg', '.bmp', '.webp', '.gif')
    files = [f for f in os.listdir(input_dir) if f.lower().endswith(supported_formats)]
    files.sort()

    if not files:
        print(f"在目录 '{input_dir}' 中没有找到支持的图片文件。")
        return

    print(f"找到 {len(files)} 个图片文件，开始转换...")
    success_count = 0

    for filename in files:
        input_path = os.path.join(input_dir, filename)
        base_name = os.path.splitext(filename)[0]

        try:
            with Image.open(input_path) as img:
                img_out = prepare_image(img, target_width, target_height, keep_size)
                width, height = img_out.size
                output_filename = f"{base_name}_{width}x{height}.bmp"
                output_path = os.path.join(output_dir, output_filename)
                img_out.save(output_path, 'BMP')
                print(f"[成功] {filename} -> {output_filename}")
                success_count += 1
        except Exception as e:
            print(f"[失败] 转换 {filename} 时发生错误: {e}")

    print(f"\n转换完成！共成功转换 {success_count} 个文件。")
    print(f"请将 '{output_dir}' 目录下的所有 BMP 文件复制到 TF(SD) 卡的根目录中。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="FPGA TF卡 BMP 图片转换工具（24位无压缩）")
    parser.add_argument('input', nargs='?', help='输入的图片文件路径 (例如: 1.jpg)')
    parser.add_argument('output', nargs='?', help='输出的BMP文件路径 (例如: 1.bmp)')
    parser.add_argument('--keep-size', action='store_true',
                        help='保持原图尺寸，只转换为 BMP；超过 1024x2047 时等比缩小')

    args = parser.parse_args()

    if args.input and args.output:
        convert_single_file(args.input, args.output, keep_size=args.keep_size)
    else:
        current_dir = os.path.dirname(os.path.abspath(__file__))
        default_input = os.path.join(current_dir, "input_images")
        default_output = os.path.join(current_dir, "output_bmp")

        print("=== FPGA TF卡 BMP 图片转换工具 ===")
        print("输出：24 位无压缩 BMP；默认 640x480，--keep-size 保持原尺寸（上限 1024x2047）")
        print("-" * 40)
        print("提示: 也可以指定单张图片转换：")
        print("python convert_images_to_bmp.py <输入文件> <输出文件> [--keep-size]")
        print("-" * 40)

        if not os.path.exists(default_input):
            os.makedirs(default_input)
            print(f"已创建默认输入目录: {default_input}")
            print("请将需要转换的图片放入该目录，然后重新运行本脚本。")
            sys.exit(0)

        convert_to_bmp(default_input, default_output, keep_size=args.keep_size)
