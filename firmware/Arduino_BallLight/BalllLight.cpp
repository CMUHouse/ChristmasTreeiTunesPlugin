

#include "BallLight.h"

static uint8_t lerp(uint8_t a, uint8_t b, uint8_t v)
{
  uint16_t sa = a;
  uint16_t sb = b;
  uint16_t mab = (sa * v) + (sb * (255 - v));
  return (uint8_t)(mab >> 8);
}

RGBColor
RGBColor::blend(RGBColor withColor, uint8_t alpha) const 
{
  RGBColor ret(0,0,0);
  ret.r = lerp(this->r, withColor.r, alpha);
  ret.g = lerp(this->g, withColor.g, alpha);
  ret.b = lerp(this->b, withColor.b, alpha);
  return ret;
}


static RGBColor default_colors[] = {
  RED,
  GREEN,
  BLUE,
  ORANGE,
  PURPLE,
  YELLOW,
  TEAL,
  INDIGO,
  WHITE,
};

static const uint8_t kWhiteIdx = (sizeof(default_colors) / sizeof(RGBColor)) - 1;


static uint8_t randomBallColorIndex()
{
    uint32_t numCols = sizeof(default_colors) / sizeof(RGBColor);
    uint32_t idx = random(numCols);
    return idx;
}

static int32_t randomizedDuration(unsigned long dur, uint8_t variance)
{
  if (variance == 0) {
    return dur;
  }

  int32_t range = (dur *  variance) / 100;
  int32_t offset = random(-range/2, range/2);
  int32_t value = dur;
  return dur + offset;
}

static RGBColor applyRandomLuminance(const RGBColor& color, uint8_t minPercent)
{
  if (minPercent >= 100) {
    return color;
  }

  uint8_t p = random(minPercent, 100);
  /*
  
  uint16_t r = color.r;
  uint16_t g = color.g;
  uint16_t b = color.b;
  r = (r * p) / 100;
  g = (g * p) / 100;
  b = (b * p) / 100;
  return RGBColor(r,g,b);
  */

  float pp = (p / 100.f);
  float lr = color.r * (1.f - (pp * 0.299f));
  float lg = color.g * (1.f - (pp * 0.587f));
  float lb = color.b * (1.f - (pp * 0.114f));

  return RGBColor(lr,lg,lb);
}

BallLight::BallLight(unsigned long animation_dur, unsigned long anim_hold, uint8_t anim_variance, uint8_t hold_variance)
: m_startColor(0,0,0)
, m_endColor(0,0,0)
, m_anim_dur_ms(animation_dur)
, m_anim_hold_ms(anim_hold)
, m_dur_variance_percentage(min(anim_variance, 100))
, m_hold_variance_percentage(min(hold_variance, 100))
, m_animStart_ms(0)
, m_animEnd_ms(0)
{

  m_startColorIdx = randomBallColorIndex();
  do {
    m_endColorIdx = randomBallColorIndex();
  } while (m_startColorIdx == m_endColorIdx);
  m_startColor = default_colors[m_startColorIdx];
  m_endColor = default_colors[m_endColorIdx];
}

void BallLight::updateForTime(unsigned long t) 
{
            
    Milliseconds offset = 0;

    const Milliseconds anim_hold = randomizedDuration(m_anim_hold_ms, m_hold_variance_percentage);
    const Milliseconds anim_dur = randomizedDuration(m_anim_dur_ms, m_dur_variance_percentage);

    if (m_animStart_ms == 0 || m_animEnd_ms == 0 || m_animStart_ms >= m_animEnd_ms) {
        m_animStart_ms = t;
        m_animEnd_ms = t + anim_dur;        
    }
    
    if (t <= m_animStart_ms) {
        m_animStart_ms = t;
        m_animEnd_ms = t + anim_dur;
        m_currColor = m_startColor;
        
    } else if (t >= m_animEnd_ms) {
        
        m_currColor = m_endColor;
        
        if (m_startColorIdx == m_endColorIdx) {
            m_endColorIdx = randomBallColorIndex();
            while (m_startColorIdx == m_endColorIdx) {
                m_endColorIdx = randomBallColorIndex();
            }
            m_endColor = default_colors[m_endColorIdx];
            if (m_endColorIdx != kWhiteIdx) {
              m_endColor = applyRandomLuminance(m_endColor, 25);
            }
            m_animStart_ms = t;
            m_animEnd_ms = t + anim_dur;
        } else {
            m_startColor = m_endColor;
            m_startColorIdx = m_endColorIdx;
            m_animStart_ms = t;
            m_animEnd_ms = t + anim_hold;
        }

        
    } else {

        Milliseconds inter = ((t - m_animStart_ms) * 255) / (m_animEnd_ms - m_animStart_ms);
        m_currColor = m_endColor.blend(m_startColor, inter);
    }
}
