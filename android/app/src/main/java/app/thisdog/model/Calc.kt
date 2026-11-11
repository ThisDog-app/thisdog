package app.thisdog.model

import app.thisdog.i18n.L
import kotlin.math.pow
import kotlin.math.roundToInt

/** Die Rechnungen der Rechner – dieselben Formeln wie Calc.swift. */
object Calc {
    /** Grundumsatz in kcal: 70 × kg^0,75. */
    fun rer(kg: Double) = 70 * kg.pow(0.75)

    data class Factor(val value: Double, val note: String)

    fun factor(p: DogProfile, today: Day = Day.today()): Factor {
        p.birthDay?.let { b ->
            val months = b.daysUntil(today) / 30.44
            if (months < 4) return Factor(3.0, L.t("Welpe bis 4 Monate, hoher Wachstumsbedarf"))
            if (months < 12) return Factor(2.0, L.t("Welpe bis 12 Monate, Wachstum"))
        }
        var f = if (p.neutered) 1.6 else 1.8
        val parts = mutableListOf(if (p.neutered) "kastriert" else L.t("nicht kastriert"))
        if (p.activity == "low") { f -= 0.2; parts += "ruhig" }
        if (p.activity == "high") { f += 0.4; parts += L.t("sehr aktiv") }
        if (p.stage(today) == L.t("Senior")) { f -= 0.2; parts += L.t("Senior") }
        return Factor(maxOf(1.0, (f * 100).roundToInt() / 100.0), parts.joinToString(", "))
    }

    data class Energy(val rer: Double, val kcal: Double, val factor: Factor, val kg: Double)

    /** Tagesbedarf; mit `useTarget` zählt das Wunschgewicht. */
    fun energy(p: DogProfile, useTarget: Boolean = false, today: Day = Day.today()): Energy? {
        val kg = (if (useTarget) (p.targetWeightKg ?: p.weightKg) else p.weightKg) ?: return null
        if (kg <= 0) return null
        val f = factor(p, today); val r = rer(kg)
        return Energy(r, r * f.value, f, kg)
    }

    fun grams(kcal: Double, kcalPer100g: Double) = if (kcalPer100g > 0) kcal / kcalPer100g * 100 else null
    /** Höchstens ein Zehntel der Tagesenergie aus Leckerli; Trockenleckerli etwa 3,5 kcal je Gramm. */
    fun treats(kcal: Double) = (kcal * 0.1) to (kcal * 0.1 / 3.5)
    /** Wasser: 50 bis 60 ml je kg und Tag. */
    fun water(kg: Double) = (kg * 50)..(kg * 60)

    enum class Paws(val label: String) { OK(L.t("Sicher")), WARN(L.t("Vorsicht")), BAD(L.t("Nicht laufen")) }
    /** Ab etwa 52 °C entstehen bei Kontakt binnen einer Minute Schäden an den Ballen; ab 43 °C wird es knapp. */
    fun paws(surface: Double) = if (surface >= 52) Paws.BAD else if (surface >= 43) Paws.WARN else Paws.OK

    fun advice(p: Paws) = when (p) {
        Paws.OK -> L.t("Unbedenklich. Trotzdem kurz mit dem Handrücken prüfen.")
        Paws.WARN -> L.t("Grenzbereich. Schattenroute wählen, Mittagshitze meiden.")
        Paws.BAD -> L.t("Zu heiß. Die Ballen können verbrennen: auf Gras ausweichen oder in die kühlen Stunden verlegen.")
    }
    val FOOD_KINDS = listOf(L.t("Trocken") to 350.0, L.t("Nass") to 95.0, L.t("Frisch, BARF") to 150.0)
}
