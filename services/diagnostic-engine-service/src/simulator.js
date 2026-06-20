/**
 * simulator.js — Realistic diagnostic result simulation for the NeuroSphere
 * AI Diagnostic Engine.
 *
 * Generates medically plausible findings, confidence scores, and recommended
 * actions based on scan_type and body_region. Findings use standard radiology
 * reporting terminology (ACR BI-RADS–style language, Fleischner criteria
 * terminology, etc.).
 */

// ─── Finding databases keyed by scan_type → body_region ──────────────────────

const FINDINGS_DB = {
  MRI: {
    head: {
      normal: [
        'No acute intracranial abnormality. Normal gray-white matter differentiation.',
        'Unremarkable MRI of the brain. No mass effect, midline shift, or hydrocephalus.',
        'Normal myelination pattern for age. No evidence of demyelinating disease.',
      ],
      abnormal: [
        'Focal T2/FLAIR hyperintensity in the right temporal lobe measuring 12mm, suggestive of low-grade glioma. Recommend contrast-enhanced follow-up.',
        'Multiple periventricular white matter lesions consistent with demyelinating disease (MS). Dawson fingers pattern noted.',
        'Acute left MCA territory infarct with restricted diffusion on DWI. No hemorrhagic transformation.',
        'Enhancing extra-axial mass in the right cerebellopontine angle, consistent with vestibular schwannoma (15 × 12 mm).',
      ],
      inconclusive: [
        'Small non-specific T2 hyperintensity in subcortical white matter. Clinical correlation recommended; may represent microvascular ischemic change vs. early demyelination.',
        'Equivocal enhancement at the tentorium. Artifact vs. pathology — recommend repeat with thin-section post-contrast sequences.',
      ],
    },
    spine: {
      normal: [
        'No significant disc herniation or spinal canal stenosis. Normal vertebral body heights and alignment.',
        'Conus medullaris terminates at L1-L2 level. No intrinsic cord signal abnormality.',
      ],
      abnormal: [
        'Large left paracentral disc extrusion at L4-L5 causing severe left lateral recess stenosis with compression of the traversing L5 nerve root.',
        'Multilevel degenerative disc disease C3-C7 with moderate central canal stenosis at C5-C6. Cord signal change noted at this level.',
        'Compression fracture at T12 with 40% height loss and mild retropulsion. Marrow edema suggests acute/subacute timeframe.',
      ],
      inconclusive: [
        'Mild disc bulge at L5-S1 with annular fissure. Clinical significance uncertain — correlate with radiculopathy symptoms.',
      ],
    },
    chest: {
      normal: ['No abnormal signal in the mediastinum or chest wall. Cardiac chambers are normal in size.'],
      abnormal: ['Enhancing mass in the anterior mediastinum measuring 4.2 × 3.8 cm, differential includes thymoma vs. lymphoma. Biopsy recommended.'],
      inconclusive: ['Indeterminate pericardial thickening. Recommend cardiac MRI with dedicated pericardial protocol.'],
    },
    abdomen: {
      normal: ['Liver, spleen, pancreas, and kidneys are unremarkable. No free fluid or lymphadenopathy.'],
      abnormal: [
        'Hepatic lesion in segment VI (3.1 cm) with arterial enhancement and washout on delayed phase, consistent with hepatocellular carcinoma (LI-RADS 5).',
        'Complex cystic lesion in the pancreatic body (Bosniak III). Endoscopic ultrasound with FNA recommended.',
      ],
      inconclusive: ['Subcentimeter hepatic lesion too small to characterize. Recommend follow-up MRI in 3 months.'],
    },
    _default: {
      normal: ['No significant abnormality detected on MRI. Findings within normal limits.'],
      abnormal: ['Abnormal signal intensity identified. Further clinical correlation and possible biopsy recommended.'],
      inconclusive: ['Findings are non-specific. Short-interval follow-up MRI recommended in 6-8 weeks.'],
    },
  },

  CT: {
    head: {
      normal: [
        'No acute intracranial hemorrhage, mass effect, or midline shift. Ventricles and sulci are age-appropriate.',
        'Non-contrast CT of the head is unremarkable. No calvarial fracture.',
      ],
      abnormal: [
        'Acute right-sided subdural hematoma with 8mm midline shift. Neurosurgical consultation recommended.',
        'Hyperdense lesion in the left basal ganglia consistent with acute hypertensive hemorrhage (25 mL estimated volume).',
        'Depressed skull fracture in the right parietal bone with underlying epidural hematoma.',
      ],
      inconclusive: [
        'Subtle hypodensity in the right insular cortex. Early ischemic change cannot be excluded — recommend CTA and perfusion imaging.',
      ],
    },
    chest: {
      normal: [
        'No pulmonary embolism. Lungs are clear bilaterally. No pleural effusion or pneumothorax.',
        'Normal CT angiography of the chest. No aortic dissection or aneurysm.',
      ],
      abnormal: [
        'Filling defect in the right lower lobe pulmonary artery consistent with acute pulmonary embolism. RV/LV ratio 1.3 suggesting right heart strain.',
        'Spiculated 2.8 cm nodule in the right upper lobe (Lung-RADS 4B). PET/CT and tissue sampling recommended.',
        'Bilateral ground-glass opacities with crazy-paving pattern. Differential includes viral pneumonitis, ARDS, or alveolar hemorrhage.',
      ],
      inconclusive: [
        'Solitary 6mm pulmonary nodule in the left lower lobe. Recommend follow-up CT in 6 months per Fleischner Society guidelines.',
      ],
    },
    abdomen: {
      normal: ['No acute intra-abdominal pathology. Appendix is normal. No free air or fluid.'],
      abnormal: [
        'Dilated appendix (11mm) with periappendiceal fat stranding and an appendicolith. Findings consistent with acute appendicitis.',
        'Large heterogeneous mass arising from the right kidney (8.5 cm), suspicious for renal cell carcinoma. No renal vein invasion.',
      ],
      inconclusive: ['Mildly prominent retroperitoneal lymph nodes (1.2 cm short axis). Non-specific — recommend follow-up imaging.'],
    },
    _default: {
      normal: ['CT examination is unremarkable. No acute findings.'],
      abnormal: ['Abnormal findings identified on CT. Clinical correlation and further workup recommended.'],
      inconclusive: ['Indeterminate finding. Follow-up imaging or additional clinical context required.'],
    },
  },

  'X-Ray': {
    chest: {
      normal: [
        'PA and lateral chest radiograph shows clear lung fields. No cardiomegaly, pleural effusion, or pneumothorax. Cardiomediastinal silhouette is normal.',
        'No acute cardiopulmonary process. Osseous structures are intact.',
      ],
      abnormal: [
        'Right lower lobe consolidation with air bronchograms consistent with community-acquired pneumonia. Small right pleural effusion.',
        'Widened mediastinum (>8 cm). Aortic dissection cannot be excluded — urgent CT angiography recommended.',
        'Left tension pneumothorax with mediastinal shift to the right. Emergent decompression indicated.',
      ],
      inconclusive: [
        'Subtle opacity at the left costophrenic angle. Small effusion vs. atelectasis — lateral decubitus view recommended.',
      ],
    },
    upper_extremity: {
      normal: ['No fracture or dislocation. Osseous structures and joint spaces are intact.'],
      abnormal: [
        'Transverse fracture of the distal radius (Colles fracture) with dorsal angulation and 3mm displacement. No intra-articular extension.',
        'Comminuted fracture of the proximal humerus involving the surgical neck with valgus impaction. Three-part fracture (Neer classification).',
      ],
      inconclusive: [
        'Equivocal lucency at the scaphoid waist. Occult fracture cannot be excluded — recommend MRI or repeat radiograph in 10-14 days.',
      ],
    },
    lower_extremity: {
      normal: ['No fracture or joint effusion. Normal alignment and joint spaces preserved.'],
      abnormal: [
        'Oblique fracture of the left femoral shaft with lateral displacement. Orthopedic consultation for intramedullary nailing.',
        'Displaced bimalleolar fracture of the right ankle (Weber B). Widened medial clear space indicates deltoid ligament injury.',
        'Lytic lesion in the proximal tibia with periosteal reaction. Differential includes osteosarcoma vs. Ewing sarcoma. Urgent MRI and biopsy recommended.',
      ],
      inconclusive: [
        'Faint periosteal reaction along the tibial diaphysis. Stress fracture vs. early infection — correlate clinically.',
      ],
    },
    _default: {
      normal: ['Radiograph shows no acute osseous abnormality.'],
      abnormal: ['Fracture or abnormality identified. Orthopedic consultation recommended.'],
      inconclusive: ['Subtle finding — recommend correlation with CT or MRI for further characterization.'],
    },
  },

  Ultrasound: {
    abdomen: {
      normal: [
        'Liver is normal in echotexture and size. No intrahepatic biliary dilatation. Gallbladder is unremarkable without stones or wall thickening.',
        'Kidneys are normal in size with preserved corticomedullary differentiation. No hydronephrosis.',
      ],
      abnormal: [
        'Multiple gallstones with gallbladder wall thickening (5mm) and positive sonographic Murphy sign. Findings consistent with acute cholecystitis.',
        'Echogenic liver consistent with hepatic steatosis (Grade II). No focal hepatic lesion.',
        'Right renal calculus measuring 8mm at the ureteropelvic junction with mild hydronephrosis.',
      ],
      inconclusive: [
        'Hypoechoic lesion in the right hepatic lobe (1.4 cm). Hemangioma vs. metastasis — recommend contrast-enhanced CT or MRI.',
      ],
    },
    pelvis: {
      normal: ['Uterus and ovaries are unremarkable. No free fluid in the cul-de-sac.'],
      abnormal: [
        'Complex adnexal mass measuring 5.2 × 4.1 cm with solid and cystic components and internal vascularity. O-RADS 4 — surgical evaluation recommended.',
        'Uterine fibroid (intramural, 4.8 cm) with heterogeneous echogenicity. No evidence of degeneration.',
      ],
      inconclusive: ['Simple cyst in the left ovary (3.2 cm). Likely physiologic — recommend follow-up ultrasound in 6 weeks.'],
    },
    neck: {
      normal: ['Thyroid gland is normal in size and echogenicity. No nodules identified.'],
      abnormal: [
        'Hypoechoic nodule in the right thyroid lobe (1.8 × 1.2 cm) with irregular margins and microcalcifications. TI-RADS 5 — FNA biopsy recommended.',
      ],
      inconclusive: ['Mixed echogenicity nodule in the left thyroid lobe (0.9 cm). TI-RADS 3 — follow-up ultrasound in 12 months.'],
    },
    _default: {
      normal: ['Ultrasound examination is unremarkable.'],
      abnormal: ['Abnormal finding on ultrasound. Further imaging or clinical correlation recommended.'],
      inconclusive: ['Indeterminate sonographic finding. Follow-up imaging recommended.'],
    },
  },

  PET: {
    whole_body: {
      normal: [
        'No abnormal FDG-avid foci to suggest metabolically active malignancy. Physiologic uptake in the brain, myocardium, liver, and urinary tract.',
      ],
      abnormal: [
        'Intensely FDG-avid mass in the right hilum (SUVmax 12.4) with ipsilateral mediastinal lymphadenopathy (SUVmax 8.7). Findings highly suspicious for primary lung malignancy with nodal metastases.',
        'Multiple FDG-avid osseous lesions throughout the axial and appendicular skeleton. Pattern consistent with widespread metastatic disease.',
        'FDG-avid lymphadenopathy above and below the diaphragm consistent with lymphoma. Recommend biopsy for histologic subtyping.',
      ],
      inconclusive: [
        'Mildly FDG-avid focus in the ascending colon (SUVmax 4.2). Physiologic vs. neoplastic uptake — colonoscopy recommended.',
      ],
    },
    chest: {
      normal: ['No hypermetabolic pulmonary or mediastinal lesion.'],
      abnormal: [
        'FDG-avid right upper lobe nodule (SUVmax 9.8) with mediastinal lymph node involvement (stations 4R and 7). Staging consistent with at least N2 disease.',
      ],
      inconclusive: ['Low-grade FDG uptake in a right lower lobe nodule (SUVmax 2.1). Inflammatory vs. neoplastic — recommend CT-guided biopsy.'],
    },
    _default: {
      normal: ['No abnormal radiotracer uptake identified on PET/CT.'],
      abnormal: ['Abnormal FDG uptake detected. Oncologic consultation recommended.'],
      inconclusive: ['Equivocal radiotracer uptake. Tissue sampling recommended for definitive diagnosis.'],
    },
  },
};

// ─── Recommended actions by result category ──────────────────────────────────

const ACTIONS = {
  normal: [
    'No further imaging required at this time.',
    'Routine follow-up per clinical guidelines.',
    'Results communicated to referring physician.',
    'Patient may resume normal activities.',
  ],
  abnormal: [
    'Urgent consultation with specialist recommended.',
    'Schedule follow-up imaging within 2 weeks.',
    'Recommend multidisciplinary tumor board review.',
    'Consider tissue biopsy for histopathologic confirmation.',
    'Correlate with laboratory values (CBC, CMP, tumor markers).',
    'Neurosurgical / orthopedic / surgical consultation indicated.',
    'Initiate treatment protocol per institutional guidelines.',
  ],
  inconclusive: [
    'Recommend short-interval follow-up imaging in 6-8 weeks.',
    'Additional imaging modality suggested for further characterization.',
    'Clinical correlation with patient history and physical examination recommended.',
    'Discuss findings at multidisciplinary conference.',
    'Consider contrast-enhanced study for better tissue characterization.',
  ],
};

// ─── Helper utilities ────────────────────────────────────────────────────────

function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

function weightedCategory() {
  // Distribution: ~55% normal, ~30% abnormal, ~15% inconclusive
  const r = Math.random();
  if (r < 0.55) return 'normal';
  if (r < 0.85) return 'abnormal';
  return 'inconclusive';
}

/**
 * Generate a simulated diagnostic result for a given job.
 *
 * @param {object} job - The job record from models.js.
 * @returns {object} Analysis result with findings, confidence, recommendations, etc.
 */
function generateDiagnosticResult(job) {
  const { scan_type, body_region } = job;

  const result_category = weightedCategory();

  // Look up findings: scan_type → body_region → category, with fallbacks.
  const scanDB = FINDINGS_DB[scan_type] || FINDINGS_DB['CT'];
  const regionDB = scanDB[body_region] || scanDB._default;
  const findingsList = regionDB[result_category] || scanDB._default[result_category];

  const primary_finding = pick(findingsList);

  // Confidence score varies by category.
  let confidence_score;
  switch (result_category) {
    case 'normal':
      confidence_score = parseFloat((0.88 + Math.random() * 0.12).toFixed(4)); // 0.88–1.0
      break;
    case 'abnormal':
      confidence_score = parseFloat((0.72 + Math.random() * 0.22).toFixed(4)); // 0.72–0.94
      break;
    case 'inconclusive':
      confidence_score = parseFloat((0.40 + Math.random() * 0.30).toFixed(4)); // 0.40–0.70
      break;
  }

  // Pick 1-3 recommended actions.
  const actionPool = ACTIONS[result_category];
  const numActions = Math.min(actionPool.length, 1 + Math.floor(Math.random() * 3));
  const shuffled = [...actionPool].sort(() => 0.5 - Math.random());
  const recommended_actions = shuffled.slice(0, numActions);

  // Simulated processing time (seconds) based on scan complexity.
  const PROCESSING_RANGES = {
    'MRI':        { min: 8,  max: 30 },
    'CT':         { min: 4,  max: 15 },
    'X-Ray':      { min: 1,  max: 5  },
    'Ultrasound': { min: 3,  max: 10 },
    'PET':        { min: 12, max: 45 },
  };
  const range = PROCESSING_RANGES[scan_type] || { min: 3, max: 15 };
  const processing_time_s = parseFloat(
    (range.min + Math.random() * (range.max - range.min)).toFixed(2)
  );

  return {
    result_category,      // 'normal' | 'abnormal' | 'inconclusive'
    primary_finding,
    confidence_score,
    recommended_actions,
    processing_time_s,
    ai_model_version: '3.7.2-neurosphere',
    analysis_timestamp: new Date().toISOString(),
  };
}

module.exports = { generateDiagnosticResult };
