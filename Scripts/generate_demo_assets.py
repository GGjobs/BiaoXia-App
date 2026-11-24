#!/usr/bin/env python3
"""Generate deterministic, entirely fictional demo inputs for BiaoXia."""

from pathlib import Path
from shutil import copy2

from PIL import Image, ImageDraw, ImageFont
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "TestAssets" / "SimulatorFiles"
RESOURCES = ROOT / "BiaoXia" / "Resources"
OUTPUT_PDF = ROOT / "output" / "pdf"
OUTPUT_IMAGES = ROOT / "output" / "images"
FONT_PATH = Path("/System/Library/Fonts/STHeiti Medium.ttc")

PROFILE = {
    "姓名": "林知夏",
    "性别": "女",
    "出生日期": "2004-09-18",
    "学校": "云岭未来大学",
    "学院": "智能工程学院",
    "专业": "数据科学与智能系统",
    "学号": "2023AI0427",
    "手机": "13800004271",
    "邮箱": "lin.zhixia@example.test",
    "地址": "云岭市新知区星河路88号7栋302室",
    "民族": "汉族",
    "籍贯": "云岭省星海市",
    "政治面貌": "共青团员",
    "学历": "本科在读",
    "班级": "数据智能 2302 班",
    "入学时间": "2023-09",
    "毕业时间": "2027-06",
}


def setup() -> None:
    for directory in (FIXTURES, RESOURCES, OUTPUT_PDF, OUTPUT_IMAGES):
        directory.mkdir(parents=True, exist_ok=True)
    pdfmetrics.registerFont(TTFont("BiaoXiaCN", FONT_PATH, subfontIndex=0))


def text(c: canvas.Canvas, value: str, x: float, y: float, size: float = 12) -> None:
    c.setFont("BiaoXiaCN", size)
    c.setFillColor(colors.HexColor("#172321"))
    c.drawString(x, y, value)


def section_header(c: canvas.Canvas, title: str, top: float) -> None:
    width, height = A4
    c.setFillColor(colors.HexColor("#DDEDE9"))
    c.roundRect(50, height - top - 28, width - 100, 28, 7, fill=1, stroke=0)
    text(c, title, 62, height - top - 19, 11)


def blank_field(
    c: canvas.Canvas,
    label: str,
    top: float,
    *,
    x: float = 50,
    width: float = 495,
    label_width: float = 95,
    height: float = 40,
) -> None:
    _, page_height = A4
    y = page_height - top - height
    c.setStrokeColor(colors.HexColor("#91AAA4"))
    c.setLineWidth(0.8)
    c.setFillColor(colors.HexColor("#F1F7F5"))
    c.rect(x, y, label_width, height, fill=1, stroke=1)
    c.setFillColor(colors.white)
    c.rect(x + label_width, y, width - label_width, height, fill=1, stroke=1)
    text(c, label, x + 12, y + height / 2 - 5, 10)


def generate_template(path: Path) -> None:
    width, height = A4
    c = canvas.Canvas(str(path), pagesize=A4, invariant=1)
    c.setTitle("表匣大学生创新竞赛报名信息表（三页演示模板）")
    c.setFillColor(colors.HexColor("#EAF4F1"))
    c.roundRect(42, height - 126, width - 84, 76, 12, fill=1, stroke=0)
    text(c, "大学生创新竞赛报名信息表", 60, height - 82, 21)
    text(c, "固定 PDF 模板 · 第 1 页 / 共 3 页", 60, height - 106, 9)

    section_header(c, "一、申请人基本信息（由建档材料自动填写）", 146)
    blank_field(c, "姓名", 186, width=300, label_width=80)
    blank_field(c, "性别", 186, x=350, width=195, label_width=70)
    blank_field(c, "出生日期", 234, label_width=80)

    section_header(c, "二、学籍信息（由学生证与成绩单核验）", 292)
    blank_field(c, "学校", 332)
    blank_field(c, "学院", 380)
    blank_field(c, "专业", 428)
    blank_field(c, "学号", 476)

    section_header(c, "三、竞赛报名信息（现场补充）", 534)
    blank_field(c, "报名赛道", 574, width=300, label_width=80)
    blank_field(c, "参赛角色", 574, x=350, width=195, label_width=80)
    blank_field(c, "项目名称", 622, label_width=80)
    blank_field(c, "项目简介", 670, label_width=80, height=72)
    text(c, "可根据简历补充项目经历与个人分工", 145, height - 730, 8)
    text(c, "模板编号：competition-registration-v1", 50, 31, 7)
    text(c, "请继续填写第 2 页的联系方式、材料核验与声明。", 300, 31, 7)
    c.showPage()

    c.setFillColor(colors.HexColor("#EAF4F1"))
    c.roundRect(42, height - 112, width - 84, 62, 12, fill=1, stroke=0)
    text(c, "大学生创新竞赛报名信息表", 60, height - 78, 17)
    text(c, "联系方式、材料核验与申请声明 · 第 2 页 / 共 3 页", 60, height - 98, 8)

    section_header(c, "四、联系方式（由简历自动填写）", 134)
    blank_field(c, "手机", 174)
    blank_field(c, "邮箱", 222)
    blank_field(c, "通讯地址", 270, height=66)

    section_header(c, "五、建档材料核验", 366)
    c.setFillColor(colors.HexColor("#F7FAF9"))
    c.setStrokeColor(colors.HexColor("#91AAA4"))
    c.roundRect(50, height - 516, width - 100, 112, 8, fill=1, stroke=1)
    text(c, "□ 虚构简历：核验学校、学院、专业与联系方式", 70, height - 432, 10)
    text(c, "□ 虚构学生证：核验姓名、性别、出生日期与学号", 70, height - 464, 10)
    text(c, "□ 虚构成绩单：核验学校、学院、专业与学号", 70, height - 496, 10)
    blank_field(c, "来源说明", 532, label_width=80, height=66)

    section_header(c, "六、申请声明", 628)
    text(c, "本人确认上述自动填写信息已经逐项核对，提交材料均用于本次演示。", 62, height - 684, 10)
    text(c, "如字段来源存在差异，以本人最终人工确认的内容为准。", 62, height - 710, 10)
    blank_field(c, "申请人签名", 730, width=300, label_width=90)
    blank_field(c, "日期", 730, x=350, width=195, label_width=60)
    text(c, "表匣固定模板 · competition-registration-v1", 50, 31, 7)
    c.showPage()

    c.setFillColor(colors.HexColor("#EAF4F1"))
    c.roundRect(42, height - 112, width - 84, 62, 12, fill=1, stroke=0)
    text(c, "大学生创新竞赛报名信息表", 60, height - 78, 17)
    text(c, "能力与经历 · 第 3 页 / 共 3 页", 60, height - 98, 8)

    section_header(c, "七、技能与证书", 134)
    blank_field(c, "技能", 174, height=58)
    blank_field(c, "证书", 240, height=82)

    section_header(c, "八、获奖与核心课程", 338)
    blank_field(c, "获奖", 378, height=82)
    blank_field(c, "核心课程", 468, height=132)

    section_header(c, "九、项目及实践经历", 616)
    blank_field(c, "经历摘要", 656, height=126)
    text(c, "表匣固定模板 · competition-registration-v1 · 第 3 页", 50, 31, 7)
    c.save()


def generate_resume(path: Path) -> None:
    width, height = A4
    c = canvas.Canvas(str(path), pagesize=A4, invariant=1)
    c.setTitle("虚构简历")
    c.setFillColor(colors.HexColor("#173F39"))
    c.rect(0, height - 138, width, 138, fill=1, stroke=0)
    c.setFillColor(colors.white)
    c.setFont("BiaoXiaCN", 25)
    c.drawString(52, height - 78, PROFILE["姓名"])
    c.setFont("BiaoXiaCN", 10)
    c.drawString(52, height - 105, "数据与智能方向学生 · 完全虚构测试材料")

    lines = [
        ("姓名", PROFILE["姓名"]),
        ("学校", PROFILE["学校"]),
        ("学院", PROFILE["学院"]),
        ("专业", PROFILE["专业"]),
        ("手机", PROFILE["手机"]),
        ("邮箱", PROFILE["邮箱"]),
        ("地址", PROFILE["地址"]),
        ("民族", PROFILE["民族"]),
        ("籍贯", PROFILE["籍贯"]),
        ("政治面貌", PROFILE["政治面貌"]),
        ("学历", PROFILE["学历"]),
        ("班级", PROFILE["班级"]),
        ("入学时间", PROFILE["入学时间"]),
        ("毕业时间", PROFILE["毕业时间"]),
    ]
    y = height - 184
    for label, value in lines:
        c.setFillColor(colors.HexColor("#55706B"))
        c.setFont("BiaoXiaCN", 10)
        c.drawString(55, y, f"{label}：")
        c.setFillColor(colors.HexColor("#172321"))
        c.setFont("BiaoXiaCN", 11)
        c.drawString(135, y, value)
        c.setStrokeColor(colors.HexColor("#D9E3E0"))
        c.line(55, y - 10, width - 55, y - 10)
        y -= 27

    details = [
        "技能：Swift、Python、SQL、Figma",
        "语言能力：大学英语六级 535 分",
        "证书：全国计算机等级考试二级 Python",
        "获奖：2025 年校级创新创业竞赛二等奖",
        "项目经历：校园数据可视化平台｜角色：项目负责人｜描述：负责需求梳理、数据清洗与移动端交互原型。",
        "项目经历：智能学习计划助手｜角色：交互设计｜描述：参与信息架构设计与隐私保护方案验证。",
        "实习经历：云岭数智实验室｜角色：数据产品实习生｜描述：参与校园数据看板需求分析与测试。",
        "校园经历：智能工程学院学生会学习部干事｜描述：组织两场学习经验分享活动。",
        "志愿经历：新知社区数字助老志愿服务｜描述：累计服务 24 小时。",
        "个人简介：关注数据智能与移动应用创新，擅长把复杂信息整理为清晰、可用的产品流程。",
    ]
    for line in details:
        text(c, line, 55, y - 6, 8)
        y -= 21

    text(c, "说明：性别、出生日期与学号请以学生证或成绩单为准；所有内容均为虚构。", 55, 48, 8)
    c.save()


def generate_transcript(path: Path) -> None:
    width, height = A4
    c = canvas.Canvas(str(path), pagesize=A4, invariant=1)
    c.setTitle("虚构成绩单")
    text(c, "云岭未来大学学生成绩单", 155, height - 70, 19)
    text(c, f"学校：{PROFILE['学校']}", 55, height - 124, 13)
    text(c, f"学院：{PROFILE['学院']}", 55, height - 158, 13)
    text(c, "专业：数据科学与智能系统（实验班）", 280, height - 158, 13)
    text(c, f"学号：{PROFILE['学号']}", 280, height - 124, 13)
    text(c, f"姓名：{PROFILE['姓名']}", 55, height - 192, 13)

    headers = ["课程", "学分", "成绩"]
    courses = [
        ("数据结构", "4.0", "92"),
        ("概率统计", "3.0", "89"),
        ("机器学习导论", "3.0", "94"),
        ("数据库系统", "3.0", "91"),
        ("信息可视化", "2.0", "88"),
    ]
    left, table_top = 55, height - 230
    widths = [310, 95, 80]
    row_height = 38
    x = left
    for header, cell_width in zip(headers, widths):
        c.setFillColor(colors.HexColor("#EAF4F1"))
        c.rect(x, table_top - row_height, cell_width, row_height, fill=1, stroke=1)
        text(c, header, x + 12, table_top - 24, 10)
        x += cell_width
    for row_index, row in enumerate(courses, start=1):
        x = left
        y = table_top - row_height * (row_index + 1)
        for value, cell_width in zip(row, widths):
            c.setFillColor(colors.white)
            c.rect(x, y, cell_width, row_height, fill=1, stroke=1)
            text(c, value, x + 12, y + 13, 10)
            x += cell_width

    y = table_top - row_height * 7 - 18
    for name, credits, score in courses:
        text(c, f"课程：{name}｜学分：{credits}｜成绩：{score}", 55, y, 8)
        y -= 19

    text(c, "本成绩单仅为软件测试样本，不对应任何真实学校或学生。", 55, 72, 8)
    c.save()


def generate_student_card(path: Path) -> None:
    width, height = 1012, 638
    image = Image.new("RGB", (width, height), "#EDF6F3")
    draw = ImageDraw.Draw(image)
    title_font = ImageFont.truetype(str(FONT_PATH), 44, index=0)
    body_font = ImageFont.truetype(str(FONT_PATH), 34, index=0)
    small_font = ImageFont.truetype(str(FONT_PATH), 19, index=0)
    draw.rounded_rectangle((24, 24, width - 24, height - 24), radius=34, fill="#F9FCFB", outline="#17463F", width=4)
    draw.rectangle((25, 25, width - 25, 142), fill="#17463F")
    draw.text((56, 56), "云岭未来大学  学生证", font=title_font, fill="white")
    draw.rounded_rectangle((58, 194, 272, 470), radius=16, fill="#D7E8E3")
    draw.ellipse((102, 224, 228, 350), fill="#7DA49B")
    draw.rounded_rectangle((86, 348, 244, 438), radius=40, fill="#7DA49B")
    lines = [
        f"姓名：{PROFILE['姓名']}     性别：{PROFILE['性别']}",
        f"出生日期：{PROFILE['出生日期']}",
        f"学院：{PROFILE['学院']}",
        f"专业：{PROFILE['专业']}",
        f"学号：{PROFILE['学号']}",
    ]
    y = 204
    for line in lines:
        draw.text((320, y), line, font=body_font, fill="#172321")
        y += 66
    draw.text((58, 532), "虚构演示证件 · 不具备任何证明效力", font=small_font, fill="#7D8F8B")
    image.save(path, optimize=True)


def main() -> None:
    setup()
    template = RESOURCES / "competition_registration_template.pdf"
    simulator_template = FIXTURES / "blank_competition_registration_form.pdf"
    resume = FIXTURES / "fictional_resume.pdf"
    transcript = FIXTURES / "fictional_transcript.pdf"
    student_card = FIXTURES / "fictional_student_card.png"

    generate_template(template)
    copy2(template, simulator_template)
    generate_resume(resume)
    generate_transcript(transcript)
    generate_student_card(student_card)

    copy2(template, OUTPUT_PDF / template.name)
    copy2(resume, OUTPUT_PDF / resume.name)
    copy2(transcript, OUTPUT_PDF / transcript.name)
    copy2(student_card, OUTPUT_IMAGES / student_card.name)
    print("Generated deterministic demo assets.")


if __name__ == "__main__":
    main()
